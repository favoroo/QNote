import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
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

/// [GradientBorderPainter] 的跨帧绘制缓存。
///
/// `AnimatedBuilder` 每帧都会新建一个 painter，缓存若放在 painter 实例里会随实例一起重建，
/// 因此由 [AnimatedGradientBorder] 的 State 持有，再传给每一帧的 painter 复用。
class GradientBorderPaintCache {
  Size? _geometrySize;
  double? _geometryStrokeWidth;
  double? _geometryBorderRadius;

  Size? _shaderSize;
  List<Color>? _shaderColors;
  List<double>? _shaderStops;
  double? _shaderRotation;

  double? _paintStrokeWidth;

  RRect? _rrect;
  Shader? _shader;
  Paint? _corePaint;
  Paint? _glowPaint;

  RRect get rrect => _rrect!;
  Paint get corePaint => _corePaint!;
  Paint get glowPaint => _glowPaint!;

  /// 按当前绘制参数刷新缓存，参数没变的部分直接复用上一帧的对象。
  void prepare({
    required Size size,
    required List<Color> colors,
    required List<double>? stops,
    required double strokeWidth,
    required double borderRadius,
    required double rotation,
  }) {
    // 几何只在尺寸 / 线宽 / 圆角变化时重建，避免每帧重新分配 RRect 与 Rect。
    if (_rrect == null ||
        _geometrySize != size ||
        _geometryStrokeWidth != strokeWidth ||
        _geometryBorderRadius != borderRadius) {
      _geometrySize = size;
      _geometryStrokeWidth = strokeWidth;
      _geometryBorderRadius = borderRadius;
      final deflatedRect = (Offset.zero & size).deflate(strokeWidth / 2);
      _rrect = RRect.fromRectAndRadius(deflatedRect, Radius.circular(math.max(0, borderRadius - strokeWidth / 2)));
    }

    // Paint 只依赖线宽：跨帧复用同一对象，每帧仅替换 shader 引用，省掉两次 Paint 分配。
    if (_corePaint == null || _paintStrokeWidth != strokeWidth) {
      _paintStrokeWidth = strokeWidth;
      _corePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeWidth;
      _glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeWidth * 2.4
        // 用「更宽 + 低透明度」替代 MaskFilter.blur：省掉每帧离屏图层与高斯模糊，
        // 观感上仍是核心描边外一层更宽、更淡的微光。
        ..colorFilter = ColorFilter.mode(Colors.white.withValues(alpha: 0.35), BlendMode.modulate);
      // 线宽变化会换新 Paint，把已有 shader 立刻接上，避免这一帧描边变透明。
      if (_shader != null) {
        _corePaint!.shader = _shader;
        _glowPaint!.shader = _shader;
      }
    }

    // 旋转角会被烘焙进 SweepGradient 生成的 shader，角度变化时必须重建 shader；
    // 尺寸 / 颜色 / stops 不变且角度相同时复用同一个 shader（例如父级重建但动画未推进）。
    final shaderChanged =
        _shader == null ||
        _shaderRotation != rotation ||
        _shaderSize != size ||
        !listEquals(_shaderColors, colors) ||
        !listEquals(_shaderStops, stops);
    if (shaderChanged) {
      _shader = SweepGradient(
        colors: colors,
        stops: stops,
        transform: RotatingGradientTransform(rotation),
      ).createShader(Offset.zero & size);
      _shaderSize = size;
      _shaderColors = colors;
      _shaderStops = stops;
      _shaderRotation = rotation;
      _corePaint!.shader = _shader;
      _glowPaint!.shader = _shader;
    }
  }
}

class GradientBorderPainter extends CustomPainter {
  final double animationValue;
  final List<Color> gradientColors;
  final List<double>? gradientStops;
  final double strokeWidth;
  final double borderRadius;

  /// 跨帧复用的绘制缓存（painter 每帧重建，缓存由外部 State 持有）。
  final GradientBorderPaintCache cache;

  GradientBorderPainter({
    required this.animationValue,
    required this.gradientColors,
    this.gradientStops,
    required this.strokeWidth,
    required this.borderRadius,
    GradientBorderPaintCache? cache,
  }) : cache = cache ?? GradientBorderPaintCache();

  @override
  void paint(Canvas canvas, Size size) {
    cache.prepare(
      size: size,
      colors: gradientColors,
      stops: gradientStops,
      strokeWidth: strokeWidth,
      borderRadius: borderRadius,
      rotation: animationValue,
    );

    // 1. 底层微光晕（Glow Layer）：更宽、更低透明度的描边营造呼吸感，避免每帧高斯模糊
    canvas.drawRRect(cache.rrect, cache.glowPaint);

    // 2. 顶层核心流光（Sharp Core Streamer）：锐利抗锯齿描边，呈现清晰灵动的流光轨迹
    canvas.drawRRect(cache.rrect, cache.corePaint);
  }

  @override
  bool shouldRepaint(covariant GradientBorderPainter oldDelegate) {
    return oldDelegate.cache != cache ||
        oldDelegate.animationValue != animationValue ||
        !listEquals(oldDelegate.gradientColors, gradientColors) ||
        !listEquals(oldDelegate.gradientStops, gradientStops) ||
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

class _AnimatedGradientBorderState extends State<AnimatedGradientBorder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  /// 绘制缓存由 State 持有，保证跨帧（跨 painter 实例）复用。
  final GradientBorderPaintCache _paintCache = GradientBorderPaintCache();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));
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
    final colors =
        widget.customColors ??
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

    final stops =
        widget.customStops ??
        const [0.00, 0.04, 0.08, 0.16, 0.28, 0.38, 0.46, 0.50, 0.54, 0.58, 0.66, 0.78, 0.88, 0.96, 1.00];

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
              cache: _paintCache,
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
