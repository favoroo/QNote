import 'dart:math' as math;
import 'package:flutter/material.dart';

class RotatingGradientTransform extends GradientTransform {
  final double percent;

  const RotatingGradientTransform(this.percent);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final double cx = bounds.left + bounds.width / 2;
    final double cy = bounds.top + bounds.height / 2;
    return Matrix4.identity()
      ..translateByDouble(cx, cy, 0.0, 1.0)
      ..rotateZ(percent * 2 * math.pi)
      ..translateByDouble(-cx, -cy, 0.0, 1.0);
  }
}

class GradientBorderPainter extends CustomPainter {
  final double animationValue;
  final List<Color> gradientColors;
  final List<double>? gradientStops;
  final double strokeWidth;
  final double borderRadius;

  GradientBorderPainter({
    required this.animationValue,
    required this.gradientColors,
    this.gradientStops,
    required this.strokeWidth,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final deflatedRect = rect.deflate(strokeWidth / 2);
    final rrect = RRect.fromRectAndRadius(
      deflatedRect,
      Radius.circular(math.max(0, borderRadius - strokeWidth / 2)),
    );

    final shader = SweepGradient(
      colors: gradientColors,
      stops: gradientStops,
      transform: RotatingGradientTransform(animationValue),
    ).createShader(rect);

    // 1. Draw the blurred glow border underneath for the "glowing" effect
    final glowPaint = Paint()
      ..strokeWidth = strokeWidth * 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0)
      ..shader = shader;

    canvas.drawRRect(rrect, glowPaint);

    // 2. Draw the main sharp flowing border on top
    final sharpPaint = Paint()
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..shader = shader;

    canvas.drawRRect(rrect, sharpPaint);
  }

  @override
  bool shouldRepaint(covariant GradientBorderPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.gradientColors != gradientColors ||
        oldDelegate.gradientStops != gradientStops ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.borderRadius != borderRadius;
  }
}

class AnimatedGradientBorder extends StatefulWidget {
  final Widget child;
  final bool isAnimating;
  final double borderRadius;
  final double strokeWidth;

  const AnimatedGradientBorder({
    super.key,
    required this.child,
    required this.isAnimating,
    this.borderRadius = 16,
    this.strokeWidth = 2,
  });

  @override
  State<AnimatedGradientBorder> createState() => _AnimatedGradientBorderState();
}

class _AnimatedGradientBorderState extends State<AnimatedGradientBorder>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    if (widget.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedGradientBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAnimating != oldWidget.isAnimating) {
      if (widget.isAnimating) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isAnimating) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final baseColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.3);

    // 采用与整体主题完美融合的“双流星追逐”流光效果
    // 使用低透明度的边框色作为基底，叠加主色调作为流光点，高级且不突兀
    final colors = [
      baseColor,
      primary.withValues(alpha: 0.5),
      primary,
      baseColor,
      baseColor,
      primary.withValues(alpha: 0.5),
      primary,
      baseColor,
      baseColor,
    ];
    
    const stops = [
      0.0,
      0.1,
      0.15,
      0.25,
      0.5,
      0.6,
      0.65,
      0.75,
      1.0,
    ];

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          foregroundPainter: GradientBorderPainter(
            animationValue: _controller.value,
            gradientColors: colors,
            gradientStops: stops,
            strokeWidth: widget.strokeWidth,
            borderRadius: widget.borderRadius,
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
