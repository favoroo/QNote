import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/journal_provider.dart';

const List<String> _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

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
  bool _hasSavedLatest = true;
  String? _lastSavedContent;
  bool _initialized = false;
  ProviderContainer? _container;

  Note? _existingNote;

  DateTime get _date => widget.date;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _scrollController = ScrollController();
    _controller.addListener(_onContentChanged);
    _loadExisting();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context, listen: false);
  }

  Future<void> _loadExisting() async {
    final note = await JournalService.instance.getNoteForDate(_date);
    if (!mounted) return;
    // 先更新基准值再赋文本，避免文本监听器误判为未保存内容
    _lastSavedContent = note?.content ?? '';
    setState(() {
      _existingNote = note;
      _controller.text = _lastSavedContent!;
      _initialized = true;
    });
  }

  void _onContentChanged() {
    if (_controller.text == _lastSavedContent) return;
    setState(() => _hasSavedLatest = false);
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _save();
    });
  }

  Future<void> _save() async {
    if (_isSaving) return;
    final content = _controller.text;
    if (content == _lastSavedContent) return;

    setState(() => _isSaving = true);
    try {
      // 内容清空时删除当天日记，返回 null
      final note = await JournalService.instance.saveJournal(_date, content);
      _lastSavedContent = content;
      _existingNote = note;
      // 保存后同步刷新时间线按钮状态与笔记列表
      if (mounted && _container != null) {
        invalidateJournal(_container!, _date);
      }
      if (mounted) setState(() => _hasSavedLatest = true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _handleBack() async {
    _autoSaveTimer?.cancel();
    await _save();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    // PopScope 已保证正常返回前完成保存，这里兜底页面被程序化移除的场景
    final unsaved = _controller.text != _lastSavedContent &&
        _controller.text != (_existingNote?.content ?? '');
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
        if (!didPop) await _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          title: Column(
            children: [
              Text(
                '${_date.month}月${_date.day}日 · ${_weekdays[_date.weekday - 1]}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              AnimatedSwitcher(
                duration: AppDurations.fast,
                child: Text(
                  _isSaving
                      ? '保存中…'
                      : _hasSavedLatest
                          ? '已保存'
                          : '未保存',
                  key: ValueKey('save_${_isSaving}_$_hasSavedLatest'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _hasSavedLatest && !_isSaving
                        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          centerTitle: true,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_controller.text.length}字',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: _initialized
            ? _buildBody(theme)
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _focusNode.requestFocus(),
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 80),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDateHeader(theme),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: _controller.text.isEmpty,
              maxLines: null,
              minLines: 12,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: theme.textTheme.bodyLarge?.copyWith(
                height: 1.8,
                letterSpacing: 0.3,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                hintText: '记录这一天的感受、想法或发生的事…',
                hintStyle: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  height: 1.8,
                ),
                filled: false,
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateHeader(ThemeData theme) {
    final isToday = _isSameDay(_date, DateTime.now());

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            _date.day.toString().padLeft(2, '0'),
            style: theme.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.tertiary,
              height: 1.2,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${_date.year}年${_date.month}月',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          if (isToday)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '今天',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
