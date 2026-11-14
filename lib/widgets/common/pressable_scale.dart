import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 统一的按压缩放反馈。
///
/// 项目里不少自绘按钮直接用 [GestureDetector]：既没有水波纹，按下时也毫无反馈。
/// 用它包一层即可获得与笔记行、记录钮一致的「按下轻微缩小、松开回弹」触感，
/// 并自动遵循系统「减弱动态效果」。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.behavior = HitTestBehavior.opaque,
    this.pressedScale = 0.94,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final HitTestBehavior behavior;
  final double pressedScale;
  final bool enabled;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  bool get _interactive => widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  /// 仅当外部真的关心长按时才注册长按识别器。
  ///
  /// GestureDetector 只要挂了 [GestureDetector.onLongPressEnd] / [GestureDetector.onLongPressCancel]
  /// 就会创建 LongPressGestureRecognizer。内层识别器在竞技场里比祖先更早命中、更早超时，
  /// 会夺走祖先的长按（历史踩坑：时间线节点的长按滑动选时间段被此拦掉）。
  /// 只用 onTap 时，长按结束/取消的复位由 onTapUp / onTapCancel 负责，无需长按识别器。
  bool get _hasLongPress => widget.enabled && widget.onLongPress != null;

  void _setPressed(bool value) {
    if (!_interactive || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      onDoubleTap: widget.enabled ? widget.onDoubleTap : null,
      onTapDown: _interactive ? (_) => _setPressed(true) : null,
      onTapUp: _interactive ? (_) => _setPressed(false) : null,
      onTapCancel: _interactive ? () => _setPressed(false) : null,
      onLongPressEnd: _hasLongPress ? (_) => _setPressed(false) : null,
      onLongPressCancel: _hasLongPress ? () => _setPressed(false) : null,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: AppMotion.duration(context, AppDurations.press),
        curve: AppCurves.standard,
        child: widget.child,
      ),
    );
  }
}
