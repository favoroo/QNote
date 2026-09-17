import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/ai/agent_turn_limit_actions.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';
import 'package:qnote_flutter/widgets/ai/quick_prompt_dialog.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';
import 'package:qnote_flutter/widgets/common/loading_ring.dart';
import 'package:qnote_flutter/widgets/common/streaming_elapsed_text.dart';
import 'package:qnote_flutter/widgets/common/thought_tail_scroll_view.dart';
import 'package:qnote_flutter/widgets/q_text_selection_toolbar.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

/// 全局小Q快捷对话面板。
///
/// 挂载于 MaterialApp.builder 的 Stack 上层，覆盖所有路由页面（含编辑器）。
/// 面板由底部导航栏中央停靠按钮长按唤起，或由「给小Q」选区菜单、
/// 外部分享自动唤起。模态弹窗打开时淡出隐藏。
class FloatingQOverlay extends ConsumerStatefulWidget {
  const FloatingQOverlay({super.key});

  @override
  ConsumerState<FloatingQOverlay> createState() => _FloatingQOverlayState();
}

class _FloatingQOverlayState extends ConsumerState<FloatingQOverlay> {
  static const double _edgeMargin = 12;

  GoRouter? _router;
  late final VoidCallback _routeListener;
  String _location = '';

  /// 面板内 SelectionArea 当前选中文本（供面板内「给小Q」工具栏引用）
  final _panelSelection = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();

    _router = ref.read(routerProvider);
    _location = _router!.routerDelegate.currentConfiguration.uri.toString();
    _routeListener = () {
      final uri = _router!.routerDelegate.currentConfiguration.uri.toString();
      if (uri == _location || !mounted) return;
      // 路由通知可能发生在 build 阶段（如 redirect），延后到帧末处理，
      // 避免 setState / 修改 Provider 在 build 期抛异常
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || uri == _location) return;
        setState(() => _location = uri);
        // 路由变化同步基础上下文：签名变化即驱动会话重置（切页丢失历史）；
        // 同时收起面板（面板不跨页面跟随，缩短全屏点击层的存活时间）
        ref.read(floatingQProvider.notifier)
          ..setBaseContext(QPageContext.fromLocation(uri))
          ..closePanel();
      });
    };
    _router!.routerDelegate.addListener(_routeListener);
    // 初始化基础页面上下文（编辑页覆盖上下文由各编辑页自行注册），同样延后到帧末
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(floatingQProvider.notifier)
          .setBaseContext(QPageContext.fromLocation(_location));
    });
  }

  @override
  void dispose() {
    _panelSelection.dispose();
    _router?.routerDelegate.removeListener(_routeListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 精确订阅：流式期间 provider 以约 60ms 节奏刷新消息/流式文本，
    // 这里只关心面板开关，避免整条悬浮层（含面板输入框）被高频重建，
    // 否则 Web 端中文输入法组合态会被反复打断（删字复活、光标错乱）
    final panelOpen = ref.watch(floatingQProvider.select((s) => s.panelOpen));
    final anchorAlignment =
        ref.watch(floatingQProvider.select((s) => s.anchorAlignment));
    final size = MediaQuery.sizeOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return ValueListenableBuilder<int>(
      valueListenable: floatingQModalCount,
      builder: (context, modalCount, _) {
        // 模态弹窗（对话框/底部弹层）打开时隐藏悬浮层。
        // 改用淡出+禁点而非整层卸载：隐藏/恢复获得淡入淡出过渡，
        // 面板开着时弹出补充提问框也不再丢失输入框文本
        final layerHidden = modalCount > 0;

        return IgnorePointer(
          ignoring: layerHidden,
          child: AnimatedOpacity(
            opacity: layerHidden ? 0 : 1,
            duration: AppDurations.normal,
            curve: Curves.easeOut,
            child: Stack(
              children: [
                // 面板打开时的全屏透明点击层：点面板外收起面板（任务继续后台执行）；
                // 常驻 + IgnorePointer 切换，避免面板收起动画期间瞬间失去点击遮挡
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !panelOpen,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          ref.read(floatingQProvider.notifier).closePanel(),
                    ),
                  ),
                ),
                // 对话面板：弹出时自底边向上生长淡入，
                // 收起时缩回淡出，动画结束才卸载（autofocus 输入框每次打开重新挂载）
                Positioned(
                  left: _edgeMargin,
                  right: _edgeMargin,
                  // 钳制上限：即使 inset 异常残留，面板也不会被推出屏幕外
                  bottom: math.min(keyboardInset, size.height * 0.55) + 12,
                  child: AnimatedSwitcher(
                    duration: AppDurations.normal,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        // 以触发按钮的底边锚点缩放：视觉上从长按的按钮位置向上展开
                        alignment: anchorAlignment,
                        scale: Tween<double>(
                          begin: 0.88,
                          end: 1,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: panelOpen
                        ? SizedBox(
                            key: const ValueKey('panel'),
                            width: double.infinity,
                            child: _FloatingQPanel(
                              onUndo: _handleUndo,
                              panelSelection: _panelSelection,
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('panel-hidden')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 撤回小Q本会话的全部修改并提示结果
  Future<void> _handleUndo() async {
    final result = await ref.read(floatingQProvider.notifier).undo();
    if (result == null || !mounted) return;
    final (restored, failed) = result;
    final toastContext = rootNavigatorKey.currentContext;
    if (toastContext == null || !toastContext.mounted) return;
    if (failed > 0) {
      Toast.warning(toastContext, '已撤回 $restored 处修改，$failed 处失败');
    } else {
      Toast.success(toastContext, '已撤回小Q的 $restored 处修改');
    }
  }
}

// ---------------------------------------------------------------------------
// 快捷对话面板
// ---------------------------------------------------------------------------
class _FloatingQPanel extends ConsumerStatefulWidget {
  final Future<void> Function() onUndo;
  final ValueNotifier<String?> panelSelection;

  const _FloatingQPanel({required this.onUndo, required this.panelSelection});

  @override
  ConsumerState<_FloatingQPanel> createState() => _FloatingQPanelState();
}

class _FloatingQPanelState extends ConsumerState<_FloatingQPanel> {
  static const double _panelMaxHeight = 380;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 精确订阅上下文徽章文案：流式刷新（约 60ms 一次）不重建面板外壳，
    // 输入行 TextField 因此保持稳定（Web 端中文 IME 组合态不被打断）
    final contextLabel = ref.watch(
      floatingQProvider.select(
        (s) => s.contextLabel ?? s.effectiveContext?.displayLabel ?? '当前页面',
      ),
    );
    // 外部分享场景：内容来自第三方应用，与当前页面无关，不展示位置徽章
    final externalShareMode = ref.watch(
      floatingQProvider.select((s) => s.externalShareMode),
    );

    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _panelMaxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(
              theme,
              externalShareMode ? '小Q' : '小Q · $contextLabel',
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Flexible(
              child: _PanelMessages(panelSelection: widget.panelSelection),
            ),
            // 撤回横幅自管显隐（内部按 phase 判定），常驻面板不自动消失
            _PanelUndoBanner(onUndo: widget.onUndo),
            // 「给小Q」引用卡片自管显隐（无挂起引用时不占位）
            const _PanelQuoteCard(),
            // 分享图片附件条自管显隐（无附件时不占位）
            const _PanelImageAttachments(),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const _PanelInputRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          const QAvatar(size: 22, withBackground: true),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 手动开启新对话（会话按界面自动隔离，这里是主动重置）
          Tooltip(
            message: '开启新对话',
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () =>
                  ref.read(floatingQProvider.notifier).newConversation(),
            ),
          ),
          // 展开到 /ai 全页面（完整对话体验）
          Tooltip(
            message: '展开全页面',
            child: IconButton(
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () {
                ref.read(floatingQProvider.notifier).closePanel();
                context.push('/ai');
              },
            ),
          ),
          Tooltip(
            message: '收起',
            child: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () =>
                  ref.read(floatingQProvider.notifier).closePanel(),
            ),
          ),
        ],
      ),
    );
  }

  /// 撤回横幅：任务完成后常驻展示（见 [_PanelUndoBanner]）
}

/// 消息区：会话消息 + 流式占位（状态文案与流式正文互斥展示）。
///
/// 独立订阅 provider：流式期间（约 60ms 一次）只有本组件重建，
/// 面板外壳与输入行保持稳定，输入框 IME 组合态不被打断
class _PanelMessages extends ConsumerStatefulWidget {
  final ValueNotifier<String?> panelSelection;

  const _PanelMessages({required this.panelSelection});

  @override
  ConsumerState<_PanelMessages> createState() => _PanelMessagesState();
}

class _PanelMessagesState extends ConsumerState<_PanelMessages> {
  final _listController = ScrollController();

  /// 是否自动贴底跟随；流式期间用户向上拖动查看历史后暂停，
  /// 拖回底部附近自动恢复（与 ThoughtTailScrollView 同一套约定）
  bool _follow = true;

  bool get _isNearBottom =>
      !_listController.hasClients ||
      _listController.position.maxScrollExtent - _listController.offset < 24;

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  /// 贴底仅在跟随态执行：jumpTo 会先终止当前滚动活动，流式期间每 60ms
  /// 一次的无条件贴底会持续打断用户拖拽，表现为回复时列表滑不动
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listController.hasClients) return;
      if (!force && !_follow) return;
      _listController.jumpTo(_listController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fq = ref.watch(floatingQProvider);

    // 消息流或流式状态变化（正文、状态文案、实时思考内容）时滚到底部：
    // 新消息落地是离散事件，强制恢复跟随并贴底；流式增量仅在跟随态贴底
    ref.listen<FloatingQState>(floatingQProvider, (prev, next) {
      final newMessage = prev?.messages.length != next.messages.length;
      if (newMessage ||
          prev?.streamingText != next.streamingText ||
          prev?.statusText != next.statusText ||
          prev?.streamingThought != next.streamingThought) {
        if (newMessage) _follow = true;
        _scrollToBottom(force: newMessage);
      }
    });

    final children = <Widget>[];

    for (final message in fq.messages) {
      // 生图结果直接以图片卡预览；其余工具中间消息不在快捷面板展示
      //（进行中的操作由状态行实时表达）
      if (message.role == 'tool') {
        final imageCard = _buildGeneratedImageCard(theme, message);
        if (imageCard != null) children.add(_buildEntrance(imageCard));
        continue;
      }
      // Agent 每轮发起工具调用前会生成「正文为空、仅承载 tool_calls」的 assistant
      // 中转消息（与 AI 主页面 _isVisibleMessage 过滤的是同一类消息），快捷面板
      // 不渲染思考胶囊，这类消息只会渲染成空白胶囊卡片，直接跳过
      if (message.content.trim().isEmpty) continue;
      children.add(_buildEntrance(_buildBubble(theme, message)));
      // 步数上限提示：待处理时在气泡下方渲染「继续/暂停」按钮
      if (message.role == 'assistant' &&
          message.uiDetails?['type'] == 'turn_limit' &&
          message.uiDetails?['handled'] != true) {
        children.add(
          AgentTurnLimitActions(
            enabled: fq.phase != FloatingQPhase.working,
            onContinue: () =>
                ref.read(floatingQProvider.notifier).continueTask(),
            onPause: () => ref.read(floatingQProvider.notifier).pauseTask(),
          ),
        );
      }
    }

    if (fq.statusText != null) {
      children.add(
        _buildEntrance(
          _buildStatusLine(theme, fq.statusText!, fq.streamingStartedAt),
        ),
      );
      // 思考中状态行下方挂实时思考尾随区（模型返回思考增量时才出现）
      final liveThought = fq.streamingThought;
      if (liveThought != null && liveThought.trim().isNotEmpty) {
        children.add(
          _buildEntrance(_buildThoughtTail(theme, liveThought.trim())),
        );
      }
    } else if (fq.streamingText != null && fq.streamingText!.isNotEmpty) {
      children.add(
        _buildEntrance(_buildAssistantBubble(theme, fq.streamingText!)),
      );
    }

    if (children.isEmpty) {
      final externalShareMode = ref.watch(
        floatingQProvider.select((s) => s.externalShareMode),
      );
      final effectiveContext = ref.watch(
        floatingQProvider.select((s) => s.effectiveContext),
      );
      final emptyPrompt = externalShareMode
          ? '让小Q处理外部导入的内容，例如"将这段文字整理并保存为笔记"或"提炼核心信息"。'
          : (effectiveContext?.emptyPromptHint ??
              QPageContext.fallback.emptyPromptHint);

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Text(
          emptyPrompt,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      );
    }

    return SelectionArea(
      // 跟踪面板内选中文本，供面板内「给小Q」工具栏引用
      onSelectionChanged: (selection) {
        widget.panelSelection.value = selection?.plainText;
      },
      contextMenuBuilder: (context, selectableRegionState) {
        final selectedText = widget.panelSelection.value;
        final hasSelection = selectedText != null && selectedText.isNotEmpty;
        return QTextSelectionToolbar(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: [
            ...selectableRegionState.contextMenuButtonItems.where(
              (item) => item.type != ContextMenuButtonType.custom,
            ),
            if (hasSelection)
              ContextMenuButtonItem(
                label: '给小Q',
                onPressed: () {
                  selectableRegionState.hideToolbar();
                  ref
                      .read(floatingQProvider.notifier)
                      .openWithQuote(
                        QTextQuote(
                          source: QQuoteSource.chat,
                          sourceId: '',
                          sourceTitle: '对话内容',
                          quotedText: selectedText,
                        ),
                      );
                },
              ),
          ],
        );
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.dragDetails != null) {
            _follow = false; // 用户主动拖动即暂停贴底跟随
          }
          if (_isNearBottom) _follow = true; // 拖回底部附近自动恢复
          return false;
        },
        child: ListView(
          controller: _listController,
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: children,
        ),
      ),
    );
  }

  /// 新内容入场微动画：淡入 + 轻微上移归位。
  ///
  /// tween 终值恒定，仅在气泡/状态行首次挂载时播放一次；流式期间约 60ms
  /// 一次的高频重建复用同一 Element，不会重复触发动画，也不产生持续重建
  Widget _buildEntrance(Widget child) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: AppDurations.fast,
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          // 位移只作用于绘制阶段，不影响布局，避免列表抖动
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// 生图工具结果卡：在快捷面板中直接预览生成的图片
  ///
  /// 仅渲染 generate_image 成功且带路径的结果，其余工具消息返回 null 由调用方跳过。
  Widget? _buildGeneratedImageCard(ThemeData theme, ChatMessage message) {
    if (message.toolName != 'generate_image' || message.isError == true) {
      return null;
    }
    final paths =
        (message.uiDetails?['paths'] as List?)?.whereType<String>().toList() ??
        const [];
    if (paths.isEmpty) return null;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 48),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final path in paths)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: UnifiedImage(imagePath: path, fit: BoxFit.cover),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(ThemeData theme, ChatMessage message) {
    if (message.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(AppRadius.medium),
          ),
          child: Text(
            message.content,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onPrimary,
            ),
          ),
        ),
      );
    }
    return _buildAssistantBubble(theme, message.content);
  }

  Widget _buildAssistantBubble(ThemeData theme, String content) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Text(content, style: theme.textTheme.bodyMedium),
      ),
    );
  }

  /// 等待态状态行：状态文案 + 思考形变无限符号动画 + 已用时递增计数
  /// （遵循小Q等待态显示规范，不用闪烁光标）
  Widget _buildStatusLine(
    ThemeData theme,
    String statusText,
    DateTime? startedAt,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              statusText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: MorphingInfinity(
              size: 20,
              strokeWidth: 1.5,
              color: theme.colorScheme.primary,
            ),
          ),
          StreamingElapsedText(
            startedAt: startedAt,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 实时思考尾随区：裸文本不加容器（面板空间小，保持轻量），
  /// 限高 2 行自动贴底滚动，随思考增量流式更新
  Widget _buildThoughtTail(ThemeData theme, String thought) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ThoughtTailScrollView(
        text: thought,
        maxHeight: 40,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        textStyle: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
          fontStyle: FontStyle.italic,
          height: 1.4,
        ),
      ),
    );
  }
}

/// 撤回横幅：有待撤回变更时常驻展示，不再自动过期——
/// 直到撤回执行（phase 回 idle）或发起新任务（变更跨任务累加）
class _PanelUndoBanner extends ConsumerWidget {
  final Future<void> Function() onUndo;

  const _PanelUndoBanner({required this.onUndo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 记录按结构相等比较：仅撤回相关状态变化时才重建横幅
    final (showBanner, undoCount, isUndoing) = ref.watch(
      floatingQProvider.select(
        (s) => (
          s.phase == FloatingQPhase.countdown,
          s.pendingUndoCount,
          s.isUndoing,
        ),
      ),
    );
    // 高度展开/收合 + 淡入：横幅插入/移除不再硬切挤压消息区；
    // 空态保持等宽零高，宽度稳定后只做高度方向动画
    return AnimatedSize(
      duration: AppDurations.normal,
      curve: Curves.easeOut,
      child: AnimatedSwitcher(
        duration: AppDurations.fast,
        switchInCurve: Curves.easeOut,
        child: showBanner
            ? Container(
                key: const ValueKey('undo-banner'),
                width: double.infinity,
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: 0.4,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.history_rounded,
                      size: 16,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '可撤回小Q本次的 $undoCount 处修改',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: isUndoing ? null : onUndo,
                      child: isUndoing
                          ? LoadingRing(
                              size: 14,
                              strokeWidth: 1.8,
                              color: theme.colorScheme.primary,
                            )
                          : const Text('撤回'),
                    ),
                  ],
                ),
              )
            : const SizedBox(
                width: double.infinity,
                key: ValueKey('undo-empty'),
              ),
      ),
    );
  }
}

/// 引用卡片：展示用户通过「给小Q」挂起的引用内容（来源 + 位置 + 文本摘录），
/// 发送时随任务注入给小Q；× 可随时移除。null 时不渲染、不占位，
/// 且只精确订阅 pendingQuote，流式刷新不重建本卡片外的面板结构
class _PanelQuoteCard extends ConsumerWidget {
  const _PanelQuoteCard();

  IconData _sourceIcon(QQuoteSource source) => switch (source) {
    QQuoteSource.note => Icons.sticky_note_2_outlined,
    QQuoteSource.diary => Icons.schedule_rounded,
    QQuoteSource.journal => Icons.menu_book_outlined,
    QQuoteSource.todo => Icons.task_alt_outlined,
    QQuoteSource.external => Icons.share_outlined,
    QQuoteSource.chat => Icons.chat_bubble_outline_rounded,
  };

  String _sourceLabel(QQuoteSource source) => switch (source) {
    QQuoteSource.note => '笔记',
    QQuoteSource.diary => '流水记录',
    QQuoteSource.journal => '每日日记',
    QQuoteSource.todo => '待办',
    QQuoteSource.external => '外部分享',
    QQuoteSource.chat => '对话内容',
  };

  /// 标题行：日记来源为日期字符串不加书名号，其余《标题》+ 位置；
  /// 外部分享无实体标题，只展示来源标签
  String _titleLine(QTextQuote quote) {
    final label = _sourceLabel(quote.source);
    // 外部分享与对话内容无实体标题，只展示来源标签
    if (quote.source == QQuoteSource.external ||
        quote.source == QQuoteSource.chat) {
      return label;
    }
    final title = quote.source == QQuoteSource.journal
        ? '$label ${quote.sourceTitle}'
        : '$label《${quote.sourceTitle}》';
    final location = quote.locationDesc;
    return location == null ? title : '$title · $location';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quote = ref.watch(floatingQProvider.select((s) => s.pendingQuote));
    if (quote == null) {
      return const SizedBox.shrink(key: ValueKey('quote-card-hidden'));
    }
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('quote-card'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              _sourceIcon(quote.source),
              size: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _titleLine(quote),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  quote.quotedText.isEmpty
                      ? (quote.locationDesc?.contains('光标') == true
                            ? '（当前位于光标处，可让小Q在此续写或编辑）'
                            : '（引用完整内容）')
                      : quote.quotedText,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              tooltip: '移除引用',
              icon: const Icon(Icons.close_rounded),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () =>
                  ref.read(floatingQProvider.notifier).clearPendingQuote(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分享图片附件条：外部分享图片唤起时展示待发送缩略图，× 可移除，
/// 发送时随消息一次性携带。无附件时不占位；挂载与 pendingImages 变化
/// 两个时机消费挂起图片（面板未开时收到分享走前者，面板开着再分享走后者）
class _PanelImageAttachments extends ConsumerStatefulWidget {
  const _PanelImageAttachments();

  @override
  ConsumerState<_PanelImageAttachments> createState() =>
      _PanelImageAttachmentsState();
}

class _PanelImageAttachmentsState
    extends ConsumerState<_PanelImageAttachments> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _consumePending();
    });
  }

  void _consumePending() =>
      ref.read(floatingQProvider.notifier).consumePendingImages();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = ref.watch(floatingQProvider.select((s) => s.attachedImages));

    ref.listen<List<String>?>(
      floatingQProvider.select((s) => s.pendingImages),
      (prev, next) {
        if (next != null && next.isNotEmpty) _consumePending();
      },
    );

    if (images.isEmpty) {
      return const SizedBox.shrink(key: ValueKey('image-attachments-hidden'));
    }

    return Container(
      key: const ValueKey('image-attachments'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: images.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final path = images[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  child: UnifiedImage(
                    imagePath: path,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
                // 移除按钮叠在缩略图右上角内侧（外溢负偏移会被 ListView 裁剪）
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () => ref
                        .read(floatingQProvider.notifier)
                        .removeAttachedImage(path),
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(
                          alpha: 0.85,
                        ),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 输入行：输入框 + 发送/停止按钮。
///
/// 输入控制器在本组件内持有，且只订阅"是否工作中"：
/// 流式刷新不重建 TextField，保证光标位置与 IME 组合态稳定
/// （修复"删除文字后再打字，刚删的字又出现"的 Web 端输入异常）
class _PanelInputRow extends ConsumerStatefulWidget {
  const _PanelInputRow();

  @override
  ConsumerState<_PanelInputRow> createState() => _PanelInputRowState();
}

class _PanelInputRowState extends ConsumerState<_PanelInputRow> {
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 物理键盘 Enter 拦截：无 Shift 即发送，Shift+Enter 放行默认换行。
  /// 软键盘行为由 textInputAction:newline 交给 IME（移动端发送一律点按钮）；
  /// 返回 handled 后 engine 不再把 Enter 送入文本输入通道，避免发送与换行叠加
  KeyEventResult _handleEnterKey(FocusNode node, KeyEvent event) {
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _handleSend();
    return KeyEventResult.handled;
  }

  Future<void> _handleSend() async {
    final fq = ref.read(floatingQProvider);
    final text = _inputController.text.trim();
    // 工作中由发送按钮转为停止按钮，键盘发送路径直接忽略（不清空已输入内容）
    if (fq.phase == FloatingQPhase.working) return;
    if (text.isEmpty && fq.attachedImages.isEmpty) return;
    HapticFeedback.lightImpact();
    _inputController.clear();
    // 发送后无需手动滚动：消息区的 listen 监听到消息数变化会自动滚到底部
    await ref.read(floatingQProvider.notifier).send(text);
  }

  void _handleStop() {
    HapticFeedback.mediumImpact();
    ref.read(floatingQProvider.notifier).stop();
  }

  /// 长按发送按钮切换小Q模型：与 AI 主页面共用同一 assistant 角色绑定，
  /// 切换为全局生效（主页面同步更新）
  Future<void> _handleModelSelect() async {
    HapticFeedback.mediumImpact();
    final selected = await showAssistantModelSelector(context, ref);
    if (selected == null || !mounted) return;
    Toast.success(context, '小Q模型已切换为 ${selected.name}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWorking = ref.watch(
      floatingQProvider.select((s) => s.phase == FloatingQPhase.working),
    );
    final externalShareMode = ref.watch(
      floatingQProvider.select((s) => s.externalShareMode),
    );
    final effectiveContext = ref.watch(
      floatingQProvider.select((s) => s.effectiveContext),
    );
    final inputHint = externalShareMode
        ? '告诉小Q如何处理这段内容…'
        : (effectiveContext?.inputHintText ??
            QPageContext.fallback.inputHintText);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 常用提示词按钮（点击弹出列表，选中即覆盖输入框）
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => showQuickPromptDialog(context, ref, (text) {
                _inputController.text = text;
                _inputController.selection = TextSelection.fromPosition(
                  TextPosition(offset: text.length),
                );
                _focusNode.requestFocus();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bolt_rounded,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '常用提示词',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: _handleEnterKey,
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    // 软键盘回车键为「换行」，发送一律点右侧按钮；
                    // 桌面/Web 物理回车在 _handleEnterKey 拦截发送，Shift+Enter 换行
                    textInputAction: TextInputAction.newline,
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(
                      hintText: inputHint,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 小Q工作中：发送按钮变为中断/停止按钮（与 AI 主页面交互一致）；
              // 空闲态长按可切换模型（工作中为停止按钮，不响应长按）。
              // 工作态外圈环绕极简细线 LoadingRing 缺口圆环旋转动画，中央为精致圆角停止方块
              isWorking
                  ? Tooltip(
                      message: '点击中止小Q当前操作',
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _handleStop();
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: theme.brightness == Brightness.dark
                                  ? 0.14
                                  : 0.08,
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: theme.brightness == Brightness.dark
                                    ? 0.22
                                    : 0.14,
                              ),
                              width: 0.8,
                            ),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              LoadingRing(
                                size: 30,
                                strokeWidth: 1.3,
                                color: theme.colorScheme.primary,
                              ),
                              Container(
                                width: 9.5,
                                height: 9.5,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(2.0),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : IconButton.filled(
                      onPressed: _handleSend,
                      onLongPress: _handleModelSelect,
                      tooltip: '发送（长按切换模型）',
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 22),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}
