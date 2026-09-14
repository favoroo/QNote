import 'package:flutter/material.dart';

/// 形变无限符号加载动画（MorphingInfinity）
///
/// 模拟圆 -> 无限符号 -> 反向圆 -> 无限符号 -> 圆的平滑流动形变循环。
/// 5 秒周期，基于 4 段三次贝塞尔曲线关键点在 24x24 视口中进行平滑插值。
class MorphingInfinity extends StatefulWidget {
  final double size;
  final Color? color;
  final double strokeWidth;
  final Duration duration;

  const MorphingInfinity({
    super.key,
    this.size = 24.0,
    this.color,
    this.strokeWidth = 1.5,
    this.duration = const Duration(seconds: 5),
  });

  @override
  State<MorphingInfinity> createState() => _MorphingInfinityState();
}

class _MorphingInfinityState extends State<MorphingInfinity>
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
  void didUpdateWidget(MorphingInfinity oldWidget) {
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
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            size: Size(widget.size, widget.size),
            painter: _MorphingInfinityPainter(
              progress: _controller.value,
              color: effectiveColor,
              strokeWidth: widget.strokeWidth * (widget.size / 24.0),
            ),
          );
        },
      ),
    );
  }
}

class _MorphingInfinityPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _MorphingInfinityPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  // 13 个关键控制点：起点 + 4 段三次贝塞尔曲线(cp1, cp2, end)
  // circleA:
  // M 12 8 C 14.21 8 16 9.79 16 12 C 16 14.21 14.21 16 12 16 C 9.79 16 8 14.21 8 12 C 8 9.79 9.79 8 12 8 Z
  static const List<Offset> _circleA = [
    Offset(12, 8),
    Offset(14.21, 8), Offset(16, 9.79), Offset(16, 12),
    Offset(16, 14.21), Offset(14.21, 16), Offset(12, 16),
    Offset(9.79, 16), Offset(8, 14.21), Offset(8, 12),
    Offset(8, 9.79), Offset(9.79, 8), Offset(12, 8),
  ];

  // infinity:
  // M 12 12 C 14 8.5 19 8.5 19 12 C 19 15.5 14 15.5 12 12 C 10 8.5 5 8.5 5 12 C 5 15.5 10 15.5 12 12 Z
  static const List<Offset> _infinity = [
    Offset(12, 12),
    Offset(14, 8.5), Offset(19, 8.5), Offset(19, 12),
    Offset(19, 15.5), Offset(14, 15.5), Offset(12, 12),
    Offset(10, 8.5), Offset(5, 8.5), Offset(5, 12),
    Offset(5, 15.5), Offset(10, 15.5), Offset(12, 12),
  ];

  // circleB:
  // M 12 16 C 14.21 16 16 14.21 16 12 C 16 9.79 14.21 8 12 8 C 9.79 8 8 9.79 8 12 C 8 14.21 9.79 16 12 16 Z
  static const List<Offset> _circleB = [
    Offset(12, 16),
    Offset(14.21, 16), Offset(16, 14.21), Offset(16, 12),
    Offset(16, 9.79), Offset(14.21, 8), Offset(12, 8),
    Offset(9.79, 8), Offset(8, 9.79), Offset(8, 12),
    Offset(8, 14.21), Offset(9.79, 16), Offset(12, 16),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 计算当前处于哪个 0.25 区间并平滑过渡 (easeInOut)
    final List<Offset> fromPoints;
    final List<Offset> toPoints;
    final double stageT;

    if (progress < 0.25) {
      fromPoints = _circleA;
      toPoints = _infinity;
      stageT = progress / 0.25;
    } else if (progress < 0.50) {
      fromPoints = _infinity;
      toPoints = _circleB;
      stageT = (progress - 0.25) / 0.25;
    } else if (progress < 0.75) {
      fromPoints = _circleB;
      toPoints = _infinity;
      stageT = (progress - 0.50) / 0.25;
    } else {
      fromPoints = _infinity;
      toPoints = _circleA;
      stageT = (progress - 0.75) / 0.25;
    }

    final easedT = Curves.easeInOut.transform(stageT.clamp(0.0, 1.0));

    // 计算插值后的 13 个点
    final currentPoints = List<Offset>.generate(13, (i) {
      return Offset.lerp(fromPoints[i], toPoints[i], easedT)!;
    });

    final path = Path();
    path.moveTo(currentPoints[0].dx * scale, currentPoints[0].dy * scale);

    for (int i = 0; i < 4; i++) {
      final cp1 = currentPoints[1 + i * 3];
      final cp2 = currentPoints[2 + i * 3];
      final end = currentPoints[3 + i * 3];
      path.cubicTo(
        cp1.dx * scale,
        cp1.dy * scale,
        cp2.dx * scale,
        cp2.dy * scale,
        end.dx * scale,
        end.dy * scale,
      );
    }

    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MorphingInfinityPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
