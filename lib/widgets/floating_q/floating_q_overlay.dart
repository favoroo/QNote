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
/// 隐藏规则：/ai 页（已有完整对话入口）、模态弹窗打开时、键盘弹起且面板未展开时。
class FloatingQOverlay extends ConsumerStatefulWidget {
  const FloatingQOverlay({super.key});

  @override
  ConsumerState<FloatingQOverlay> createState() => _FloatingQOverlayState();
}

class _FloatingQOverlayState extends ConsumerState<FloatingQOverlay> {
  static const double _ballSize = 56;
  static const double _edgeMargin = 16;

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
    // 初始化基础页面上下文（编辑页压栈的覆盖上下文由各编辑页自行注册）
    ref
        .read(floatingQProvider.notifier)
        .setBaseContext(QPageContext.fromLocation(_location));
    _routeListener = () {
      final uri = _router!.routerDelegate.currentConfiguration.uri.toString();
      if (uri == _location || !mounted) return;
      setState(() => _location = uri);
      // 路由变化同步基础上下文：签名变化即驱动会话重置（切页丢失历史）
      ref
          .read(floatingQProvider.notifier)
          .setBaseContext(QPageContext.fromLocation(uri));
    };
    _router!.routerDelegate.addListener(_routeListener);
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_routeListener);
    super.dispose();
  }

  Offset _defaultBallPosition(Size size) =>
      Offset(size.width - _ballSize - _edgeMargin, size.height - _ballSize - 96);

  void _onPanUpdate(DragUpdateDetails details) {
    final size = MediaQuery.sizeOf(context);
    final current = _ballPosition ?? _defaultBallPosition(size);
    final dx = (current.dx + details.delta.dx)
        .clamp(_edgeMargin, size.width - _ballSize - _edgeMargin);
    final dy = (current.dy + details.delta.dy)
        .clamp(_edgeMargin, size.height - _ballSize - _edgeMargin);
    setState(() => _ballPosition = Offset(dx, dy));
  }

  @override
  Widget build(BuildContext context) {
    final fq = ref.watch(floatingQProvider);
    final size = MediaQuery.sizeOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final isAiPage = _location.startsWith('/ai');

    return ValueListenableBuilder<int>(
      valueListenable: floatingQModalCount,
      builder: (context, modalCount, _) {
        // /ai 页有完整小Q对话；模态弹窗（对话框/底部弹层）与键盘输入时避免悬浮层遮挡。
        // 面板展开时随键盘上移，保持可见
        if (isAiPage || modalCount > 0 || (keyboardInset > 0 && !fq.panelOpen)) {
          return const SizedBox.shrink();
        }

        return Stack(
          children: [
            // 面板打开时的全屏透明点击层：点面板外收起面板（任务继续后台执行）
            if (fq.panelOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      ref.read(floatingQProvider.notifier).closePanel(),
                ),
              ),
            if (fq.panelOpen)
              Positioned(
                left: _edgeMargin,
                right: _edgeMargin,
                bottom: keyboardInset + 12,
                child: _FloatingQPanel(onUndo: _handleUndo),
              )
            else
              Positioned(
                left: (_ballPosition ?? _defaultBallPosition(size)).dx,
                top: (_ballPosition ?? _defaultBallPosition(size)).dy,
                child: _FloatingBall(
                  size: _ballSize,
                  phase: fq.phase,
                  countdownEndsAt: fq.countdownEndsAt,
                  pendingUndoCount: fq.pendingUndoCount,
                  onTap: () =>
                      ref.read(floatingQProvider.notifier).openPanel(),
                  onPanUpdate: _onPanUpdate,
                  onUndo: _handleUndo,
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
class _FloatingBall extends StatelessWidget {
  final double size;
  final FloatingQPhase phase;
  final DateTime? countdownEndsAt;
  final int pendingUndoCount;
  final VoidCallback onTap;
  final void Function(DragUpdateDetails) onPanUpdate;
  final Future<void> Function() onUndo;

  const _FloatingBall({
    required this.size,
    required this.phase,
    required this.countdownEndsAt,
    required this.pendingUndoCount,
    required this.onTap,
    required this.onPanUpdate,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      onPanUpdate: onPanUpdate,
      child: switch (phase) {
        FloatingQPhase.working => _WorkingBall(size: size),
        FloatingQPhase.countdown => _CountdownBall(
            size: size,
            endsAt: countdownEndsAt,
            undoCount: pendingUndoCount,
            onUndo: onUndo,
          ),
        _ => Container(
            width: size,
            height: size,
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
              size: 28,
            ),
          ),
      },
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

/// 撤回倒计时悬浮球：环形进度（5s→0）+ 撤回图标，点击执行撤回
class _CountdownBall extends StatefulWidget {
  final double size;
  final DateTime? endsAt;
  final int undoCount;
  final Future<void> Function() onUndo;

  const _CountdownBall({
    required this.size,
    required this.endsAt,
    required this.undoCount,
    required this.onUndo,
  });

  @override
  State<_CountdownBall> createState() => _CountdownBallState();
}

class _CountdownBallState extends State<_CountdownBall>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final remaining =
        widget.endsAt?.difference(DateTime.now()) ?? const Duration(seconds: 5);
    _controller = AnimationController(
      vsync: this,
      duration: remaining <= Duration.zero
          ? const Duration(milliseconds: 1)
          : remaining,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    HapticFeedback.mediumImpact();
    await widget.onUndo();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.surface.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: widget.size - 6,
                  height: widget.size - 6,
                  child: CircularProgressIndicator(
                    value: 1 - _controller.value,
                    strokeWidth: 3,
                    color: theme.colorScheme.tertiary,
                    backgroundColor: Colors.transparent,
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Icon(
                  Icons.undo_rounded,
                  color: theme.colorScheme.onTertiaryContainer,
                  size: 26,
                ),
              ],
            ),
          );
        },
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
  final _inputController = TextEditingController();
  final _listController = ScrollController();
  static const double _panelMaxHeight = 380;

  @override
  void dispose() {
    _inputController.dispose();
    _listController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listController.hasClients) return;
      _listController.jumpTo(_listController.position.maxScrollExtent);
    });
  }

  Future<void> _handleSend() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    _inputController.clear();
    await ref.read(floatingQProvider.notifier).send(text);
    _scrollToBottom();
  }

  void _handleStop() {
    HapticFeedback.mediumImpact();
    ref.read(floatingQProvider.notifier).stop();
  }

  void _handleNewConversation() {
    ref.read(floatingQProvider.notifier).newConversation();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fq = ref.watch(floatingQProvider);
    final isWorking = fq.phase == FloatingQPhase.working;

    // 消息流或流式状态变化时滚到底部
    ref.listen<FloatingQState>(floatingQProvider, (prev, next) {
      if (prev?.messages.length != next.messages.length ||
          prev?.streamingText != next.streamingText) {
        _scrollToBottom();
      }
    });

    final contextLabel = fq.contextLabel ??
        fq.effectiveContext?.displayLabel ??
        '当前页面';

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
            Flexible(child: _buildMessageArea(theme, fq)),
            if (fq.phase == FloatingQPhase.countdown)
              _buildUndoBanner(theme, fq),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            _buildInputRow(theme, isWorking),
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
              onPressed: _handleNewConversation,
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

  /// 消息区：会话消息 + 流式占位（状态文案与流式正文互斥展示）
  Widget _buildMessageArea(ThemeData theme, FloatingQState fq) {
    final children = <Widget>[];

    for (final message in fq.messages) {
      // 工具中间消息不在快捷面板展示（进行中的操作由状态行实时表达）
      if (message.role == 'tool') continue;
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

  /// 撤回倒计时横幅：任务完成后 5 秒内可撤回
  Widget _buildUndoBanner(ThemeData theme, FloatingQState fq) {
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
              '可撤回小Q本次的 ${fq.pendingUndoCount} 处修改',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: fq.isUndoing ? null : () => widget.onUndo(),
            child: fq.isUndoing
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

  Widget _buildInputRow(ThemeData theme, bool isWorking) {
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
