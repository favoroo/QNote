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

    // 1. 底层微光晕（Glow Layer）：精致轻度微光营造呼吸感，剔除脏乱大范围光晕
    final glowPaint = Paint()
      ..strokeWidth = strokeWidth * 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0)
      ..shader = shader;

    canvas.drawRRect(rrect, glowPaint);

    // 2. 顶层核心流光（Sharp Core Streamer）：锐利抗锯齿描边，呈现清晰灵动的流光轨迹
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
      duration: const Duration(milliseconds: 2000),
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

    // 轨道基底透明色：超轻量主题基色，保持圆环轨道的精致完整性
    final baseColor = primary.withValues(alpha: isDark ? 0.12 : 0.08);

    // 纯粹主题色动态流光色谱：
    // 以 App 强调色为核心，告别杂乱的霓虹杂色，呈现纯净、极简、富有科技动感的流光质感
    final sparkWhite = Color.lerp(primary, Colors.white, isDark ? 0.88 : 0.92)!;
    final sparkHighlight = Color.lerp(primary, Colors.white, 0.45)!;
    final corePrimary = primary;
    final tailMid = primary.withValues(alpha: isDark ? 0.65 : 0.55);
    final tailFade = primary.withValues(alpha: isDark ? 0.20 : 0.14);

    // 双流星对称追逐流光：两道主题色灵动流星环绕旋转，兼顾动感、平衡与简约美感
    final colors = widget.customColors ??
        [
          baseColor,
          sparkWhite,
          sparkHighlight,
          corePrimary,
          tailMid,
          tailFade,
          baseColor,
          baseColor,
          sparkWhite,
          sparkHighlight,
          corePrimary,
          tailMid,
          tailFade,
          baseColor,
          baseColor,
        ];

    final stops = widget.customStops ??
        const [
          0.00,
          0.04,
          0.08,
          0.16,
          0.28,
          0.38,
          0.46,
          0.50,
          0.54,
          0.58,
          0.66,
          0.78,
          0.88,
          0.96,
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
