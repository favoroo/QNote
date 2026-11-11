part of 'floating_q_overlay.dart';

// 最小化后的圆形气泡：视觉与拖动手势。
// 幽灵（变形落位）和真实气泡共用同一套视觉，保证交接时像素一致。

/// 气泡视觉：主色圆底 + 小Q头像 + 工作中环形进度 + 未读点。
class _FloatingQBubbleVisual extends StatelessWidget {
  const _FloatingQBubbleVisual({required this.working, required this.unread});

  /// 小Q是否正在执行任务（外圈转动的缺口圆环）
  final bool working;

  /// 最小化期间是否收到了新的完成回复（右上角小圆点）
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: _kBubbleSize,
      height: _kBubbleSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 圆底与阴影独立于 QAvatar：变形容器用同一套 _bubbleShadow 插值，
          // 幽灵换成真实气泡时阴影不会跳一下
          Container(
            width: _kBubbleSize,
            height: _kBubbleSize,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              boxShadow: [_bubbleShadow(scheme)],
            ),
            child: Center(
              child: QAvatar(
                size: _kBubbleSize * 0.54,
                color: scheme.onPrimary,
                screenColor: scheme.primary,
                eyeColor: scheme.onPrimary,
              ),
            ),
          ),
          if (working)
            SizedBox(
              width: _kBubbleSize,
              height: _kBubbleSize,
              child: LoadingRing(size: _kBubbleSize, strokeWidth: 1.6, color: scheme.onPrimary),
            ),
          if (unread)
            Positioned(
              top: 1,
              right: 1,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: scheme.tertiary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 可拖动气泡：点击重新打开弹窗，长按后跟手拖动，松手由父层磁吸回边。
///
/// 位置由父层统一 clamp（安全区/键盘），这里只负责把手指位移换算成
/// 新的左上角坐标；[AnimatedPositioned] 在松手后播放磁吸回弹。
class _FloatingQBubble extends StatefulWidget {
  const _FloatingQBubble({
    super.key,
    required this.position,
    required this.working,
    required this.unread,
    required this.onTap,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  /// 气泡左上角（父层已 clamp）。
  final Offset position;

  final bool working;
  final bool unread;
  final VoidCallback onTap;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_FloatingQBubble> createState() => _FloatingQBubbleState();
}

class _FloatingQBubbleState extends State<_FloatingQBubble> {
  bool _dragging = false;
  Offset? _dragStartGlobal;
  Offset? _dragStartPosition;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: _dragging ? Duration.zero : _kBubbleSnapDuration,
      curve: Curves.easeOutCubic,
      left: widget.position.dx,
      top: widget.position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPressStart: (details) {
          HapticFeedback.mediumImpact();
          setState(() {
            _dragging = true;
            _dragStartGlobal = details.globalPosition;
            _dragStartPosition = widget.position;
          });
        },
        onLongPressMoveUpdate: (details) {
          final start = _dragStartGlobal;
          final origin = _dragStartPosition;
          if (start == null || origin == null) return;
          widget.onDragUpdate(origin + (details.globalPosition - start));
        },
        onLongPressEnd: (_) {
          setState(() {
            _dragging = false;
            _dragStartGlobal = null;
            _dragStartPosition = null;
          });
          widget.onDragEnd();
        },
        child: AnimatedScale(
          scale: _dragging ? 1.08 : 1.0,
          duration: AppDurations.fast,
          curve: Curves.easeOutCubic,
          child: _FloatingQBubbleVisual(working: widget.working, unread: widget.unread),
        ),
      ),
    );
  }
}
