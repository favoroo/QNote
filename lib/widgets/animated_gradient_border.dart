import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Listenable, listEquals;
import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/utils/shimmer_palette.dart';

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

  /// 已应用的整体亮度，避免每帧重复设置同样的 ColorFilter。
  double? _intensity;

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
        ..strokeWidth = strokeWidth * 2.8;
      // 线宽变化会换新 Paint，把已有 shader 立刻接上，避免这一帧描边变透明。
      if (_shader != null) {
        _corePaint!.shader = _shader;
        _glowPaint!.shader = _shader;
      }
      // 新 Paint 还没有颜色过滤，下一帧由 [applyIntensity] 重新挂上。
      _intensity = null;
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

  /// 把整体亮度（淡入淡出 × 呼吸）作用到描边上。
  ///
  /// 用 `ColorFilter.modulate` 缩放 alpha，而不是重建整组颜色：
  /// 每帧只需一个很轻的过滤对象，shader 与几何不必因为透明度变化而重建；
  /// 同时透明度只影响描边，不会连带淡化卡片正文与图片。
  void applyIntensity(double intensity) {
    if (_intensity == intensity) {
      return;
    }
    _intensity = intensity;
    _corePaint!.colorFilter = intensity >= 0.999
        ? null
        : ColorFilter.mode(Colors.white.withValues(alpha: intensity), BlendMode.modulate);
    // 光晕固定是核心亮度的 20%：更宽、更淡的一圈，形成柔和的呼吸感。
    _glowPaint!.colorFilter = ColorFilter.mode(Colors.white.withValues(alpha: intensity * 0.20), BlendMode.modulate);
  }
}

class GradientBorderPainter extends CustomPainter {
  final double animationValue;

  /// 整体亮度（淡入淡出 × 呼吸），通过 Paint 颜色过滤缩放描边 alpha。
  final double intensity;

  final List<Color> gradientColors;
  final List<double>? gradientStops;
  final double strokeWidth;
  final double borderRadius;

  /// 跨帧复用的绘制缓存（painter 每帧重建，缓存由外部 State 持有）。
  final GradientBorderPaintCache cache;

  GradientBorderPainter({
    required this.animationValue,
    this.intensity = 1,
    required this.gradientColors,
    this.gradientStops,
    required this.strokeWidth,
    required this.borderRadius,
    GradientBorderPaintCache? cache,
  }) : cache = cache ?? GradientBorderPaintCache();

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0.001) {
      return;
    }

    cache.prepare(
      size: size,
      colors: gradientColors,
      stops: gradientStops,
      strokeWidth: strokeWidth,
      borderRadius: borderRadius,
      rotation: animationValue,
    );
    cache.applyIntensity(intensity);

    // 1. 底层柔光晕：更宽、更低透明度的描边营造呼吸感，避免每帧高斯模糊
    canvas.drawRRect(cache.rrect, cache.glowPaint);

    // 2. 顶层核心流光：锐利抗锯齿描边，呈现清晰灵动的流光轨迹
    canvas.drawRRect(cache.rrect, cache.corePaint);
  }

  @override
  bool shouldRepaint(covariant GradientBorderPainter oldDelegate) {
    return oldDelegate.cache != cache ||
        oldDelegate.animationValue != animationValue ||
        oldDelegate.intensity != intensity ||
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

class _AnimatedGradientBorderState extends State<AnimatedGradientBorder> with TickerProviderStateMixin {
  /// 流光环绕一周的时长。
  ///
  /// 旧版 2s 一圈在卡片尺寸下显得急促，像警报灯；3.6s 更接近「光缓缓流过边缘」。
  static const Duration _cycle = Duration(milliseconds: 3600);

  late final AnimationController _rotation;
  late final AnimationController _presence;
  late final Listenable _ticker;

  /// 绘制缓存由 State 持有，保证跨帧（跨 painter 实例）复用。
  final GradientBorderPaintCache _paintCache = GradientBorderPaintCache();

  /// 系统「减弱动态效果」。null 表示尚未从 MediaQuery 读取。
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(vsync: this, duration: _cycle);
    _presence = AnimationController(vsync: this, duration: AppDurations.normal);
    _ticker = Listenable.merge([_rotation, _presence]);
    _presence.addStatusListener(_onPresenceStatus);
    // 首帧就处于提取态（例如列表滚动后重建）时直接显示，不补一次淡入。
    if (widget.isAnimating) {
      _presence.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = AppMotion.reduce(context);
    if (_reduceMotion == reduceMotion) {
      return;
    }
    _reduceMotion = reduceMotion;
    _syncPlayback();
  }

  @override
  void didUpdateWidget(covariant AnimatedGradientBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAnimating != oldWidget.isAnimating) {
      _syncPlayback();
    }
  }

  /// 按「是否提取中 / 是否减弱动效」统一收口两个控制器的状态。
  ///
  /// 停止提取时先淡出（[_presence] 反向播放），淡出结束再停旋转；
  /// 这样描边不会在提取结束的瞬间硬切消失。
  void _syncPlayback() {
    if (!mounted) {
      return;
    }
    if (_reduceMotion == true) {
      // 减弱动效：不转、不闪，只保留一圈静态柔光，提取中的状态仍能被看到。
      _rotation.stop();
      _presence.value = widget.isAnimating ? 1 : 0;
      return;
    }
    if (widget.isAnimating) {
      _presence.forward();
      if (!_rotation.isAnimating) {
        _rotation.repeat();
      }
      return;
    }
    _presence.reverse();
    if (_presence.isDismissed) {
      _rotation.stop();
    }
  }

  void _onPresenceStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.isAnimating) {
      _rotation.stop();
    }
  }

  @override
  void dispose() {
    _presence.removeStatusListener(_onPresenceStatus);
    _rotation.dispose();
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final staticShimmer = _reduceMotion == true && widget.isAnimating;
    final visible = staticShimmer || widget.isAnimating || !_presence.isDismissed;
    if (!visible) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final palette = widget.customColors != null
        ? ShimmerPalette(colors: widget.customColors!, stops: widget.customStops ?? shimmerPaletteStops)
        : buildShimmerPalette(primary: theme.colorScheme.primary, brightness: theme.brightness);

    // 隔离流光动画的重绘层，避免每帧触发父级重绘。
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ticker,
        builder: (context, child) {
          // 透明度与呼吸走描边 Paint 的颜色过滤：不能给整棵子树套 Opacity，
          // 否则卡片正文和图片会跟着一起变淡。
          final intensity = staticShimmer
              ? 1.0
              : AppCurves.emphasized.transform(_presence.value) *
                    // 一次呼吸与旋转同周期：接缝处相位连续，不会突然亮一下。
                    (0.94 + 0.06 * math.sin(_rotation.value * 2 * math.pi));
          if (intensity <= 0.001) {
            return child!;
          }
          return CustomPaint(
            foregroundPainter: GradientBorderPainter(
              animationValue: staticShimmer ? 0.0 : _rotation.value,
              intensity: intensity,
              gradientColors: palette.colors,
              gradientStops: palette.stops,
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
