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

  /// 确定进度（0~1）。非 null 时改画整圈进度弧，不再自转。
  ///
  /// 批量提取这类「总量已知、逐条推进」的场景里，自转圆环只能表达「在忙」，
  /// 用户看不出还剩多少；进度弧配合 `N/M` 文案才能判断要不要等下去。
  final double? progress;

  const LoadingRing({
    super.key,
    this.size = 24.0,
    this.color,
    this.strokeWidth = 1.4,
    this.duration = const Duration(milliseconds: 1000),
    this.progress,
  });

  @override
  State<LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<LoadingRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    // 确定进度的调用方不需要自转，等 didChangeDependencies 读动画开关会多跑一帧
    if (widget.progress == null) {
      _controller.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce == _reduceMotion) return;
    _reduceMotion = reduce;
    _syncPlayback();
  }

  /// 按「减弱动效 / 是否有确定进度」统一收口自转状态。
  ///
  /// 确定进度时不需要自转：进度弧本身就在变化，再叠一层旋转会让「还差多少」
  /// 这个信息变得不可读。
  void _syncPlayback() {
    if (_reduceMotion || widget.progress != null) {
      _controller.stop();
      _controller.value = 0.0;
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(LoadingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.progress != null || widget.progress != null || oldWidget.duration != widget.duration) {
      _syncPlayback();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.color ?? Theme.of(context).colorScheme.primary;
    final progress = widget.progress;

    // 确定进度：画一整圈极淡底轨 + 一段进度弧，不再旋转
    if (progress != null) {
      return RepaintBoundary(
        child: CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _LoadingRingProgressPainter(
            color: effectiveColor,
            strokeWidth: widget.strokeWidth * (widget.size / 24.0),
            progress: progress.clamp(0.0, 1.0),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: RotationTransition(
        key: const ValueKey('loading_ring_spin'),
        turns: _controller,
        child: CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _LoadingRingPainter(color: effectiveColor, strokeWidth: widget.strokeWidth * (widget.size / 24.0)),
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

  _LoadingRingPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(strokeWidth, 0.5)
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

/// 确定进度圆环：底轨 + 进度弧。
///
/// 用 `drawArc` 而不是沿 SVG path 截取：进度弧从 -90°（正上方）顺时针增长，
/// 起点与自转态的缺口位置一致，两种形态切换时视觉不跳。
class _LoadingRingProgressPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double progress;

  _LoadingRingProgressPainter({required this.color, required this.strokeWidth, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.width - strokeWidth * scale) / 2,
    );
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(strokeWidth, 0.5) * scale;

    // 底轨压到 22%：要让用户看出「这是一整圈」，又不能和进度弧抢注意力
    canvas.drawArc(rect, 0, math.pi * 2, false, base..color = color.withValues(alpha: 0.22));
    if (progress > 0) {
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, base..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _LoadingRingProgressPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth || oldDelegate.progress != progress;
  }
}
