import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 极简缺口圆环匀速旋转加载动画（LoadingRing）
///
/// 遵循 loading-ui.com 的 Ring 设计：
/// 缺口圆弧（约 288° / 1.6π）1 秒匀速 360 度旋转，末端带圆角。
class LoadingRing extends StatefulWidget {
  final double size;
  final Color? color;
  final double strokeWidth;
  final Duration duration;

  const LoadingRing({
    super.key,
    this.size = 24.0,
    this.color,
    this.strokeWidth = 2.0,
    this.duration = const Duration(milliseconds: 1000),
  });

  @override
  State<LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<LoadingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat();
  }

  @override
  void didUpdateWidget(LoadingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        widget.color ?? Theme.of(context).colorScheme.primary;

    return RepaintBoundary(
      child: RotationTransition(
        turns: _controller,
        child: CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _LoadingRingPainter(
            color: effectiveColor,
            strokeWidth: widget.strokeWidth * (widget.size / 24.0),
          ),
        ),
      ),
    );
  }
}

class _LoadingRingPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  // 缓存标准 24x24 视口中的 SVG Path
  // 起点 (21, 12)，顺时针旋转至约 (14.781, 3.44044)
  static final Path _ringPath = _buildPath();

  static Path _buildPath() {
    final path = Path();
    path.moveTo(21.0, 12.0004);
    path.cubicTo(20.9999, 13.901, 20.3981, 15.7528, 19.2809, 17.2904);
    path.cubicTo(18.1637, 18.8279, 16.5885, 19.9723, 14.7809, 20.5596);
    path.cubicTo(12.9733, 21.1469, 11.0262, 21.1468, 9.21864, 20.5594);
    path.cubicTo(7.41109, 19.9721, 5.83588, 18.8276, 4.71876, 17.29);
    path.cubicTo(3.60165, 15.7523, 2.99999, 13.9005, 3.0, 11.9999);
    path.cubicTo(3.00001, 10.0993, 3.60171, 8.24755, 4.71884, 6.70994);
    path.cubicTo(5.83598, 5.17233, 7.4112, 4.02785, 9.21877, 3.44052);
    path.cubicTo(11.0263, 2.85319, 12.9734, 2.85316, 14.781, 3.44044);
    return path;
  }

  _LoadingRingPainter({
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(strokeWidth, 1.0)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.save();
    canvas.scale(scale, scale);
    canvas.drawPath(_ringPath, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoadingRingPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}
