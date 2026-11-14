import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/agent/services/q_target_bridge.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/utils/q_cursor_context.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/journal_provider.dart';
import 'package:qnote_flutter/widgets/q_text_selection_toolbar.dart';

const List<String> _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const List<String> _fullWeekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

/// 每日日记编辑页：从时间线悬浮按钮或笔记板块的日记文件夹进入，
/// 标题固定为日期（YYYY-MM-DD），自动保存到对应月份的日记子文件夹。
class JournalEditorView extends ConsumerStatefulWidget {
  final DateTime date;

  const JournalEditorView({required this.date, super.key});

  @override
  ConsumerState<JournalEditorView> createState() => _JournalEditorViewState();
}

class _JournalEditorViewState extends ConsumerState<JournalEditorView> {
  late final TextEditingController _controller;
  late final ScrollController _scrollController;
  final FocusNode _focusNode = FocusNode();

  Timer? _autoSaveTimer;
  bool _isSaving = false;
  String? _lastSavedContent;
  bool _initialized = false;
  bool _suppressContentListener = false;
  bool _showAppBarTitle = false;
  ProviderContainer? _container;

  Note? _existingNote;

  // 全局悬浮小Q联动：页面上下文注册（撤销工作区修改后需重载编辑器）
  late final QPageContext _qContext;

  DateTime get _date => widget.date;

  /// 当天日期字符串（YYYY-MM-DD），小Q引用与上下文注册共用
  String get _dateStr =>
      '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _scrollController = ScrollController();
    _controller.addListener(_onContentChanged);
    _scrollController.addListener(_onScroll);
    _loadExisting();

    // 注册悬浮小Q页面上下文与重载钩子：任务结束后从 JournalService 重读，
    // 避免编辑器旧内容在小Q修改后仍被防抖保存覆盖
    _qContext = QPageContext(
      type: QContextType.journal,
      targetId: _dateStr,
      targetTitle: _dateStr,
      signature: 'journal:$_dateStr',
      displayLabel: '每日日记 $_dateStr',
    );
    ref.read(floatingQProvider.notifier).pushOverlayContext(_qContext);
    QTargetBridge.instance.register(
      _qContext.signature,
      QTargetHooks(
        fingerprint: () => _controller.text,
        reload: _reloadFromJournal,
        // 框选状态下点悬浮球时捕获选中文本引用给小Q
        quoteSelection: _captureSelectionQuote,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  Future<void> _loadExisting() async {
    final note = await JournalService.instance.getNoteForDate(_date);
    if (!mounted) {
      return;
    }
    // 先更新基准值再赋文本，避免文本监听器误判为未保存内容
    _lastSavedContent = note?.content ?? '';
    _suppressContentListener = true;
    _controller.text = _lastSavedContent!;
    _suppressContentListener = false;
    setState(() {
      _existingNote = note;
      _initialized = true;
    });
  }

  void _onScroll() {
    final shouldShow = _scrollController.hasClients && _scrollController.offset > 48;
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
  }

  void _onContentChanged() {
    if (_suppressContentListener) {
      return;
    }
    // 改回与已保存内容一致时取消待触发的保存，避免无改动也写一次库
    if (_controller.text == _lastSavedContent) {
      _autoSaveTimer?.cancel();
      return;
    }
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        _save();
      }
    });
  }

  Future<void> _save() async {
    if (_isSaving) {
      return;
    }
    final content = _controller.text;
    if (content == _lastSavedContent) {
      return;
    }

    _isSaving = true;
    try {
      // 内容清空时删除当天日记，返回 null
      final note = await JournalService.instance.saveJournal(_date, content);
      _lastSavedContent = content;
      _existingNote = note;
      // 保存后同步刷新时间线按钮状态与笔记列表
      if (mounted && _container != null) {
        invalidateJournal(_container!, _date);
      }
    } finally {
      _isSaving = false;
    }
  }

  /// 悬浮小Q任务结束后重读当天日记刷新编辑器
  /// （桥接仅在用户任务期间未手动编辑时调用）
  Future<void> _reloadFromJournal() async {
    final note = await JournalService.instance.getNoteForDate(_date);
    if (!mounted) {
      return;
    }
    _lastSavedContent = note?.content ?? '';
    _suppressContentListener = true;
    _controller.text = _lastSavedContent!;
    _suppressContentListener = false;
    setState(() {
      _existingNote = note;
    });
  }

  /// 捕获当前框选内容为引用（选择菜单「给小Q」与悬浮球点按共用）。
  /// 优先次序：正文聚焦且有选区 → 引用选中文本与行号；
  /// 聚焦但未框选（仅光标）→ 摘录光标前后上下文并标记【光标】，
  /// 让长按空白处点「给小Q」也能把光标位置带给小Q；
  /// 未聚焦正文时返回 null，避免陈旧选区被误引用
  QTextQuote? _captureSelectionQuote() {
    if (!_focusNode.hasFocus) return null;
    final sel = _controller.selection;
    final text = _controller.text;
    if (!sel.isValid) return null;

    // 1. 选区非空：引用选中的文本
    if (!sel.isCollapsed) {
      final quoted = text.substring(sel.start, sel.end).trim();
      if (quoted.isNotEmpty) {
        final line = '\n'.allMatches(text.substring(0, sel.start)).length + 1;
        return QTextQuote(
          source: QQuoteSource.journal,
          sourceId: _dateStr,
          sourceTitle: _dateStr,
          quotedText: quoted,
          locationDesc: '第 $line 行附近',
        );
      }
    }

    // 2. 光标处（未框选文字）：摘录光标前后上下文并标记【光标】
    final offset = sel.baseOffset.clamp(0, text.length);
    final line = '\n'.allMatches(text.substring(0, offset)).length + 1;
    final snippet = buildCursorContextSnippet(text, offset);
    return QTextQuote(
      source: QQuoteSource.journal,
      sourceId: _dateStr,
      sourceTitle: _dateStr,
      quotedText: snippet.isEmpty ? '（第 $line 行空行光标处）' : snippet,
      locationDesc: '第 $line 行光标处',
    );
  }

  /// 「给小Q」：把选中文本或光标位置连同近似行号引用给悬浮小Q，
  /// 便于用户让小Q修改这段指定文本、在光标处续写或针对它提问
  void _sendSelectionToQ() {
    final quote = _captureSelectionQuote();
    if (quote == null) return;
    // 收起键盘与选择菜单，把焦点让给小Q面板输入框（选中文本已在上面捕获）
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(floatingQProvider.notifier).openWithQuote(quote);
  }

  Future<void> _handleBack() async {
    _autoSaveTimer?.cancel();
    await _save();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    // 注销悬浮小Q上下文与重载钩子（容器在 didChangeDependencies 已捕获）
    QTargetBridge.instance.unregister(_qContext.signature);
    _container?.read(floatingQProvider.notifier).popOverlayContext(_qContext);
    _autoSaveTimer?.cancel();
    // PopScope 已保证正常返回前完成保存，这里兜底页面被程序化移除的场景
    final unsaved = _controller.text != _lastSavedContent && _controller.text != (_existingNote?.content ?? '');
    if (unsaved) {
      JournalService.instance.saveJournal(_date, _controller.text);
      // dispose 中不能修改 Provider，用微任务在容器仍可用时失效缓存
      final container = _container;
      final date = _date;
      Future.microtask(() {
        if (container != null) invalidateJournal(container, date);
      });
    }
    _controller.removeListener(_onContentChanged);
    _scrollController.removeListener(_onScroll);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          await _handleBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: theme.scaffoldBackgroundColor,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _handleBack),
          // 顶部信息头在视口内时保持顶栏留白，避免日期重复；滚出后淡入紧凑日期提醒当前所在天
          title: AnimatedOpacity(
            opacity: _showAppBarTitle ? 1.0 : 0.0,
            duration: AppMotion.duration(context, AppDurations.fast),
            child: Text(
              '${_date.month}月${_date.day}日 · ${_weekdays[_date.weekday - 1]}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          centerTitle: true,
          // 右侧只放与左侧返回键等宽的占位：不放保存状态/字数，标题保持真正居中
          actions: const [SizedBox(width: kToolbarHeight)],
        ),
        body: _initialized ? _buildBody(theme) : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _focusNode.requestFocus(),
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 96),
            child: ConstrainedBox(
              // 撑满剩余可视高度，保证点击正文下方大面积留白也能直接唤起输入焦点
              constraints: BoxConstraints(minHeight: (constraints.maxHeight - 104).clamp(0.0, double.infinity)),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  // 宽屏下限制单行最大阅读宽度，移动端仍占满可用内容区
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDateHeader(theme),
                      Divider(
                        height: 1,
                        thickness: 0.8,
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: _controller.text.isEmpty,
                        maxLines: null,
                        minLines: 12,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.75, letterSpacing: 0.2),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          // 清除全局 inputDecorationTheme 的水平内边距，使正文与日期头左缘严格对齐
                          contentPadding: EdgeInsets.zero,
                          hintText: '记录这一天的感受与想法…',
                          hintStyle: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.42),
                            height: 1.75,
                            letterSpacing: 0.2,
                          ),
                          filled: false,
                          isDense: true,
                        ),
                        // 系统默认项（过滤第三方文本处理项）+ 末尾「给小Q」：把选中文本
                        // 连同位置引用给悬浮小Q；用平铺工具栏避免「给小Q」被折叠进 ⋮
                        contextMenuBuilder: (context, editableTextState) {
                          return QTextSelectionToolbar(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems: [
                              ...QTextSelectionToolbar.defaultButtonItems(editableTextState),
                              ContextMenuButtonItem(label: '给小Q', onPressed: _sendSelectionToQ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDateHeader(ThemeData theme) {
    final isToday = _isSameDay(_date, DateTime.now());
    final isDark = theme.brightness == Brightness.dark;
    // 日期主色使用可读强调色，在浅色/深色与主题色/自定义背景下均保持主题呼应与对比度
    final accent = theme.accentInk;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            _date.day.toString().padLeft(2, '0'),
            style: theme.textTheme.displayMedium?.copyWith(
              fontSize: 44,
              fontWeight: FontWeight.w700,
              color: accent,
              height: 1.0,
              letterSpacing: -1.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_date.year}年${_date.month}月',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                    ),
                    if (isToday) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: isDark ? 0.16 : 0.10),
                          borderRadius: BorderRadius.circular(100),
                          border: theme.accentNeedsOutline
                              ? Border.all(color: accent.withValues(alpha: 0.35), width: 0.8)
                              : null,
                        ),
                        child: Text(
                          '今天',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _fullWeekdays[_date.weekday - 1],
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}
