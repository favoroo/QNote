import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/common/animated_ellipsis.dart';

/// 全局悬浮小Q入口：悬浮球 + 快捷对话面板。
///
/// 挂载于 MaterialApp.builder 的 Stack 上层，覆盖所有路由页面（含编辑器）。
/// 隐藏规则：/ai 页（已有完整对话入口）、模态弹窗打开时。
/// 键盘弹起时不隐藏，改为整体上移钳制避让，保证悬浮层任何时刻可见可点。
class FloatingQOverlay extends ConsumerStatefulWidget {
  const FloatingQOverlay({super.key});

  @override
  ConsumerState<FloatingQOverlay> createState() => _FloatingQOverlayState();
}

class _FloatingQOverlayState extends ConsumerState<FloatingQOverlay> {
  /// 球直径与时间线页"智能提取"悬浮按钮（44×44）保持一致
  static const double _ballSize = 44;
  static const double _edgeMargin = 16;

  /// 默认位置的底部净空：底部导航栏(60) + 收起态日记输入条(约48) +
  /// 提取按钮(bottom 12 + 高 44) + 间距 12，球正好悬停在提取按钮正上方
  static const double _ballBottomClearance = 176;

  GoRouter? _router;
  late final VoidCallback _routeListener;
  String _location = '';

  /// 悬浮球位置（相对屏幕左上角）；null 表示使用默认右下角位置
  Offset? _ballPosition;

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
        ref
            .read(floatingQProvider.notifier)
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
    _router?.routerDelegate.removeListener(_routeListener);
    super.dispose();
  }

  Offset _defaultBallPosition(Size size) => Offset(
      size.width - _ballSize - _edgeMargin,
      size.height - _ballSize - _ballBottomClearance);

  /// 悬浮球显示位置：拖动存储位置基础上，键盘弹起时整体上移钳制避让。
  /// 渲染期计算、不改存储值，键盘收起自动回位；inset 异常残留时球也始终可见可点
  Offset _displayBallPosition(Size size, double keyboardInset) {
    final base = _ballPosition ?? _defaultBallPosition(size);
    final maxTop = size.height - keyboardInset - _ballSize - _edgeMargin;
    return Offset(
      base.dx.clamp(
          _edgeMargin, math.max(_edgeMargin, size.width - _ballSize - _edgeMargin)),
      math.min(base.dy, math.max(_edgeMargin, maxTop)),
    );
  }

  void _onDragBall(Offset newTopLeft) {
    final size = MediaQuery.sizeOf(context);
    final dx = newTopLeft.dx
        .clamp(_edgeMargin, size.width - _ballSize - _edgeMargin);
    final dy = newTopLeft.dy
        .clamp(_edgeMargin, size.height - _ballSize - _edgeMargin);
    setState(() => _ballPosition = Offset(dx, dy));
  }

  @override
  Widget build(BuildContext context) {
    // 精确订阅：流式期间 provider 以约 60ms 节奏刷新消息/流式文本，
    // 这里只关心面板开关与工作态，避免整条悬浮层（含面板输入框）被高频重建，
    // 否则 Web 端中文输入法组合态会被反复打断（删字复活、光标错乱）
    final panelOpen = ref.watch(floatingQProvider.select((s) => s.panelOpen));
    final isWorking = ref.watch(
        floatingQProvider.select((s) => s.phase == FloatingQPhase.working));
    final size = MediaQuery.sizeOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final isAiPage = _location.startsWith('/ai');

    return ValueListenableBuilder<int>(
      valueListenable: floatingQModalCount,
      builder: (context, modalCount, _) {
        // /ai 页有完整小Q对话；模态弹窗（对话框/底部弹层）打开时隐藏悬浮层。
        // 键盘弹起不再隐藏，改为钳制上移，杜绝 inset 异常残留导致的"永久消失"
        if (isAiPage || modalCount > 0) {
          return const SizedBox.shrink();
        }

        return Stack(
          children: [
            // 面板打开时的全屏透明点击层：点面板外收起面板（任务继续后台执行）
            if (panelOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      ref.read(floatingQProvider.notifier).closePanel(),
                ),
              ),
            if (panelOpen)
              Positioned(
                left: _edgeMargin,
                right: _edgeMargin,
                // 钳制上限：即使 inset 异常残留，面板也不会被推出屏幕外
                bottom: math.min(keyboardInset, size.height * 0.55) + 12,
                child: _FloatingQPanel(onUndo: _handleUndo),
              )
            else
              Positioned(
                left: _displayBallPosition(size, keyboardInset).dx,
                top: _displayBallPosition(size, keyboardInset).dy,
                child: _FloatingBall(
                  size: _ballSize,
                  position: _displayBallPosition(size, keyboardInset),
                  isWorking: isWorking,
                  onTap: () =>
                      ref.read(floatingQProvider.notifier).openPanel(),
                  onDragUpdate: _onDragBall,
                ),
              ),
          ],
        );
      },
    );
  }

  /// 撤回小Q本会话的全部修改并提示结果
  Future<void> _handleUndo() async {
    final result = await ref.read(floatingQProvider.notifier).undo();
    if (result == null) return;
    final (restored, failed) = result;
    final toastContext = rootNavigatorKey.currentContext;
    if (toastContext == null) return;
    if (failed > 0) {
      Toast.warning(toastContext, '已撤回 $restored 处修改，$failed 处失败');
    } else {
      Toast.success(toastContext, '已撤回小Q的 $restored 处修改');
    }
  }
}

// ---------------------------------------------------------------------------
// 悬浮球
// ---------------------------------------------------------------------------
class _FloatingBall extends StatefulWidget {
  final double size;

  /// 当前显示位置（左上角，已含键盘避让钳制），作为拖动位移基准
  final Offset position;

  /// 任务执行中（显示工作动画球）
  final bool isWorking;
  final VoidCallback onTap;

  /// 拖动回调：新的球左上角位置（屏幕坐标，未钳制，由宿主钳制后存储）
  final ValueChanged<Offset> onDragUpdate;

  const _FloatingBall({
    required this.size,
    required this.position,
    required this.isWorking,
    required this.onTap,
    required this.onDragUpdate,
  });

  @override
  State<_FloatingBall> createState() => _FloatingBallState();
}

/// 用原始 [Listener] 而非 GestureDetector 实现点击与拖动：
/// Listener 不参与手势竞技场，指针事件分发阶段必定到达本组件，
/// 即使某个手势识别器异常卡住竞技场，悬浮球也始终保持可点可拖
/// （修复"球看得见但点不动、拖不动，需重启才恢复"的问题）
class _FloatingBallState extends State<_FloatingBall> {
  /// 拖动判定阈值（逻辑像素）：位移超过该值视为拖动而非点击
  static const double _dragSlop = 8;

  Offset? _pointerStart;
  Offset? _origin;
  bool _dragging = false;

  void _onPointerDown(PointerDownEvent event) {
    // 只跟踪首个按下的指针，多指触控时忽略后续指针
    _pointerStart ??= event.position;
    _origin ??= widget.position;
    _dragging = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _pointerStart;
    final origin = _origin;
    if (start == null || origin == null) return;
    if (!_dragging && (event.position - start).distance > _dragSlop) {
      _dragging = true;
      HapticFeedback.selectionClick();
    }
    if (_dragging) {
      widget.onDragUpdate(origin + (event.position - start));
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final wasDragging = _dragging;
    _pointerStart = null;
    _origin = null;
    _dragging = false;
    if (!wasDragging) {
      HapticFeedback.lightImpact();
      widget.onTap();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerStart = null;
    _origin = null;
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      // 撤回入口只保留在面板横幅中：悬浮球不再切换撤回倒计时形态，
      // 撤回就绪期点击球同样是弹出面板
      child: widget.isWorking
          ? _WorkingBall(size: widget.size)
          : Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.surface.withValues(alpha: 0.6),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(
                Icons.smart_toy_rounded,
                color: theme.colorScheme.onPrimary,
                // 图标随球缩小（44px），与提取按钮的图标比例一致
                size: 20,
              ),
            ),
    );
  }
}

/// 工作中悬浮球：外圈脉冲呼吸环 + 三点渐显动画
class _WorkingBall extends StatefulWidget {
  final double size;

  const _WorkingBall({required this.size});

  @override
  State<_WorkingBall> createState() => _WorkingBallState();
}

class _WorkingBallState extends State<_WorkingBall>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // 呼吸环随脉冲放大并淡出，表达"正在处理"
        final ringScale = 1.0 + _pulse.value * 0.25;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Transform.scale(
              scale: ringScale,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary
                      .withValues(alpha: 0.35 * (1 - _pulse.value)),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.colorScheme.surface.withValues(alpha: 0.6),
            width: 1.5,
          ),
        ),
        child: const Center(
          child: AnimatedEllipsis(dotSize: 5, dotSpacing: 2.5),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 快捷对话面板
// ---------------------------------------------------------------------------
class _FloatingQPanel extends ConsumerStatefulWidget {
  final Future<void> Function() onUndo;

  const _FloatingQPanel({required this.onUndo});

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
    final contextLabel = ref.watch(floatingQProvider.select(
        (s) => s.contextLabel ?? s.effectiveContext?.displayLabel ?? '当前页面'));

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
            _buildHeader(theme, contextLabel),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const Flexible(child: _PanelMessages()),
            // 撤回横幅自管显隐（内部按 phase 判定），常驻面板不自动消失
            _PanelUndoBanner(onUndo: widget.onUndo),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const _PanelInputRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String contextLabel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          Icon(Icons.smart_toy_rounded,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '小Q · $contextLabel',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
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
  const _PanelMessages();

  @override
  ConsumerState<_PanelMessages> createState() => _PanelMessagesState();
}

class _PanelMessagesState extends ConsumerState<_PanelMessages> {
  final _listController = ScrollController();

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listController.hasClients) return;
      _listController.jumpTo(_listController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fq = ref.watch(floatingQProvider);

    // 消息流或流式状态变化时滚到底部
    ref.listen<FloatingQState>(floatingQProvider, (prev, next) {
      if (prev?.messages.length != next.messages.length ||
          prev?.streamingText != next.streamingText) {
        _scrollToBottom();
      }
    });

    final children = <Widget>[];

    for (final message in fq.messages) {
      // 工具中间消息不在快捷面板展示（进行中的操作由状态行实时表达）
      if (message.role == 'tool') continue;
      // Agent 每轮发起工具调用前会生成「正文为空、仅承载 tool_calls」的 assistant
      // 中转消息（与 AI 主页面 _isVisibleMessage 过滤的是同一类消息），快捷面板
      // 不渲染思考胶囊，这类消息只会渲染成空白胶囊卡片，直接跳过
      if (message.content.trim().isEmpty) continue;
      children.add(_buildBubble(theme, message));
    }

    if (fq.statusText != null) {
      children.add(_buildStatusLine(theme, fq.statusText!));
    } else if (fq.streamingText != null && fq.streamingText!.isNotEmpty) {
      children.add(
        _buildAssistantBubble(theme, fq.streamingText!),
      );
    }

    if (children.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Text(
          '让小Q处理当前页面的内容，例如"优化这篇笔记的表达"。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView(
      controller: _listController,
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: children,
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
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onPrimary),
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
        child: SelectableText(
          content,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }

  /// 等待态状态行：状态文案 + 动态省略号（遵循小Q等待态显示规范，不用闪烁光标）
  Widget _buildStatusLine(ThemeData theme, String statusText) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
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
          const SizedBox(width: 4),
          const Padding(
            padding: EdgeInsets.only(bottom: 3),
            child: AnimatedEllipsis(),
          ),
        ],
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
    if (!showBanner) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.history_rounded,
              size: 16, color: theme.colorScheme.tertiary),
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
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('撤回'),
          ),
        ],
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

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    _inputController.clear();
    // 发送后无需手动滚动：消息区的 listen 监听到消息数变化会自动滚到底部
    await ref.read(floatingQProvider.notifier).send(text);
  }

  void _handleStop() {
    HapticFeedback.mediumImpact();
    ref.read(floatingQProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWorking = ref.watch(
        floatingQProvider.select((s) => s.phase == FloatingQPhase.working));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _handleSend(),
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: '告诉小Q要做什么…',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.5),
                ),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  borderSide:
                      BorderSide(color: theme.colorScheme.primary, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 小Q工作中：发送按钮变为中断/停止按钮（与 AI 主页面交互一致）
          IconButton.filled(
            onPressed: isWorking ? _handleStop : _handleSend,
            tooltip: isWorking ? '点击中止小Q当前操作' : '发送',
            style: IconButton.styleFrom(
              backgroundColor: isWorking
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.primary,
            ),
            icon: Icon(
              isWorking ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              size: 22,
              color: isWorking
                  ? theme.colorScheme.onErrorContainer
                  : theme.colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
