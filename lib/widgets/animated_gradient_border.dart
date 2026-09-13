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

    // 1. 底层扩散光晕（Glow Layer）：大半径高斯模糊营造发光环境等离子光感
    final glowPaint = Paint()
      ..strokeWidth = strokeWidth * 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5)
      ..shader = shader;

    canvas.drawRRect(rrect, glowPaint);

    // 2. 顶层核心流光（Sharp Core Streamer）：锐利抗锯齿描边，呈现清晰粒子轨迹
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
  final List<Color>? customColors;
  final List<double>? customStops;

  const AnimatedGradientBorder({
    super.key,
    required this.child,
    required this.isAnimating,
    this.borderRadius = 16,
    this.strokeWidth = 2,
    this.customColors,
    this.customStops,
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
      duration: const Duration(milliseconds: 2400),
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
    final isDark = theme.brightness == Brightness.dark;

    // 基底过渡透明色
    final baseColor = isDark
        ? theme.colorScheme.outlineVariant.withValues(alpha: 0.15)
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.25);

    // AI 极光多光谱流光色谱：电光青 -> 主题蓝 -> 智感紫罗兰 -> 核心纯白高光 -> 极光品红
    final cyan = const Color(0xFF00E5FF).withValues(alpha: isDark ? 0.85 : 0.75);
    final violet = const Color(0xFF8A2BE2).withValues(alpha: isDark ? 0.9 : 0.8);
    final whiteHighlight = Colors.white.withValues(alpha: isDark ? 0.95 : 0.9);
    final magenta = const Color(0xFFFF4081).withValues(alpha: isDark ? 0.75 : 0.65);

    // 采用“对称双流星追逐”极光效果，两道多光谱流星环绕旋转
    final colors = widget.customColors ??
        [
          baseColor,
          cyan,
          primary,
          violet,
          whiteHighlight,
          magenta,
          baseColor,
          baseColor,
          cyan,
          primary,
          violet,
          whiteHighlight,
          magenta,
          baseColor,
          baseColor,
        ];

    final stops = widget.customStops ??
        const [
          0.00,
          0.08,
          0.14,
          0.19,
          0.23,
          0.27,
          0.36,
          0.50,
          0.58,
          0.64,
          0.69,
          0.73,
          0.77,
          0.86,
          1.00,
        ];

    // 隔离流光动画的重绘层，避免每帧触发父级重绘
    return RepaintBoundary(
      child: AnimatedBuilder(
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
      ),
    );
  }
}
