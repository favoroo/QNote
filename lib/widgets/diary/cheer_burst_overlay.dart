import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/utils/cheer_burst.dart';

/// 以今日进度圆环为爆点的彩带迸发层。
///
/// 纯自绘（CustomPainter + AnimationController），不引第三方粒子包：项目现有动效
/// 全是这套路子，而且色谱必须由用户选的强调色派生，素材型方案做不到跟随主题。
///
/// 只负责画，不吃也不挡手势 —— 调用方需自行套 [IgnorePointer]，否则这层铺满
/// body 的画布会把时间线的滚动和两个 FAB 的点击全吞掉。
class CheerBurstOverlay extends StatefulWidget {
  const CheerBurstOverlay({
    super.key,
    required this.level,
    required this.seed,
    required this.anchor,
    this.onFinished,
  });

  /// 庆祝强度：决定粒子数量与整段时长。
  final CheerLevel level;

  /// 粒子随机种子：用庆祝事件序号即可，让连续的两次爆发长得不一样。
  final int seed;

  /// 爆点坐标（全局坐标系），由圆环实时上报。
  final ValueListenable<Offset?> anchor;

  /// 粒子散尽后回调一次。
  final VoidCallback? onFinished;

  @override
  State<CheerBurstOverlay> createState() => _CheerBurstOverlayState();
}

class _CheerBurstOverlayState extends State<CheerBurstOverlay> with SingleTickerProviderStateMixin {
  /// 涟漪单独比彩带短：先「砰」一下，彩带随后散开，层次比一起炸更清楚。
  static const double _rippleSpanMs = 520;

  /// 挂在本层根节点上，用来把圆环上报的全局坐标换算成这一层的局部坐标。
  final GlobalKey _rootKey = GlobalKey();

  List<CheerParticle> _particles = const [];
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _particles = seedBurst(count: widget.level.particleCount, seed: widget.seed);
    _controller = AnimationController(vsync: this, duration: widget.level.burstDuration)
      ..addStatusListener(_onStatusChanged);
    if (_particles.isNotEmpty) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(CheerBurstOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level == widget.level && oldWidget.seed == widget.seed) {
      return;
    }
    // 档位或种子变了就整段重播。调用方既可以像日记页那样先摘再挂，也可以直接改
    // 属性复用同一个 element —— 后者若不支持就会静默留着上一档的粒子在播。
    _particles = seedBurst(count: widget.level.particleCount, seed: widget.seed);
    _controller.duration = widget.level.burstDuration;
    if (_particles.isEmpty) {
      _controller.value = 0;
    } else {
      _controller.forward(from: 0);
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) {
      return;
    }
    // 播完就停：ticker 留着只会白白占一条每帧重绘链。
    _controller.stop();
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_onStatusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_particles.isEmpty || MediaQuery.of(context).disableAnimations) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final palette = burstPalette(scheme);
    final baseAlpha = scheme.brightness == Brightness.dark ? 0.95 : 0.90;

    // anchor 变化才重建（爆点位置几乎不动），每帧重绘交给 CustomPaint.repaint，
    // 这样 AnimationController 不会把整个子树逐帧 rebuild。
    return ValueListenableBuilder<Offset?>(
      valueListenable: widget.anchor,
      builder: (context, anchor, child) {
        return RepaintBoundary(
          key: _rootKey,
          child: CustomPaint(
            painter: _BurstPainter(
              particles: _particles,
              progress: _controller,
              totalMs: (_controller.duration ?? Duration.zero).inMilliseconds.toDouble(),
              burstDelayMs: widget.level.burstDelayMs.toDouble(),
              rippleSpanMs: _rippleSpanMs,
              origin: _toLocalOrigin(anchor),
              palette: palette,
              baseAlpha: baseAlpha,
            ),
            child: child,
          ),
        );
      },
      // 撑满 Positioned.fill 的父约束，让画布覆盖整块 body。
      child: const SizedBox.expand(),
    );
  }

  /// 全局 → 本层局部。首帧本层还没布局，先原样返回：此时粒子几乎没位移，
  /// 一帧的偏差看不出来，比引入 postFrame 协调更划算。
  Offset? _toLocalOrigin(Offset? globalAnchor) {
    if (globalAnchor == null) {
      return null;
    }
    final box = _rootKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return globalAnchor;
    }
    return box.globalToLocal(globalAnchor);
  }
}

/// 彩带色谱：全部以用户强调色为根派生。
///
/// 主题的 `secondary` 是去饱和灰、`tertiary` 是固定青色，都不跟随强调色
/// （见 `app_theme.dart`），直接拿来当彩带色会和用户选的强调色打架。
/// 因此只在 tertiary 上做少量混合增加热闹感，高光与深色端也都从 primary 走。
List<Color> burstPalette(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;
  return [
    scheme.primary,
    // 少量互补色：浅色下混得少一点，避免在接近纯白的底色上显脏。
    Color.lerp(scheme.primary, scheme.tertiary, isDark ? 0.5 : 0.35)!,
    // 高光：深色底要提亮才看得见；浅色底一提亮就糊成白，所以压得很低。
    Color.lerp(scheme.primary, Colors.white, isDark ? 0.6 : 0.25)!,
    // 深色端：保证浅色背景下最暗那棵也有足够对比度。
    Color.lerp(scheme.primary, scheme.onSurface, isDark ? 0.0 : 0.30)!,
  ];
}

class _BurstPainter extends CustomPainter {
  _BurstPainter({
    required this.particles,
    required this.progress,
    required this.totalMs,
    required this.burstDelayMs,
    required this.rippleSpanMs,
    required this.origin,
    required this.palette,
    required this.baseAlpha,
  }) : super(repaint: progress);

  final List<CheerParticle> particles;

  /// 整段动画进度，直接由 controller 提供：paint 时每帧读最新值。
  final Animation<double> progress;
  final double totalMs;
  final double burstDelayMs;
  final double rippleSpanMs;

  /// 已换算到本层坐标系的爆点；null 表示圆环还没上报过。
  final Offset? origin;
  final List<Color> palette;
  final double baseAlpha;

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = progress.value * totalMs;
    final center = resolveBurstOrigin(anchor: origin, size: size);

    _paintRipple(canvas, center, elapsed);
    _paintParticles(canvas, center, elapsed, size);
  }

  void _paintRipple(Canvas canvas, Offset center, double elapsed) {
    final t = ((elapsed - burstDelayMs) / rippleSpanMs).clamp(0.0, 1.0);
    if (t <= 0 || t >= 1) {
      return;
    }
    final eased = AppCurves.emphasized.transform(t);
    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 - 2.5 * eased
      ..color = palette.first.withValues(alpha: (0.45 * (1 - eased)).clamp(0.0, 1.0));
    canvas.drawCircle(center, 22 + 70 * eased, _paint);
  }

  void _paintParticles(Canvas canvas, Offset center, double elapsed, Size size) {
    for (final p in particles) {
      final t = (elapsed - burstDelayMs - p.delayMs) / p.lifeMs;
      if (t <= 0 || t >= 1) {
        continue;
      }
      final offset = particleOffset(p, t);
      final at = center + offset;
      // 出界早退：飞走的粒子没必要再算一次路径。
      if (at.dx < -40 || at.dx > size.width + 40 || at.dy < -40 || at.dy > size.height + 40) {
        continue;
      }
      final alpha = particleAlpha(p, t) * baseAlpha;
      if (alpha <= 0.001) {
        continue;
      }

      _paint
        ..style = PaintingStyle.fill
        ..color = palette[p.colorIndex % palette.length].withValues(alpha: alpha);

      canvas.save();
      canvas.translate(at.dx, at.dy);
      switch (p.shape) {
        case CheerShape.ribbon:
          canvas.rotate(p.spin * t * math.pi);
          final tumble = ribbonTumble(p, t);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset.zero, width: 4 * tumble, height: 9),
              const Radius.circular(1.6),
            ),
            _paint,
          );
        case CheerShape.dot:
          canvas.drawCircle(Offset.zero, 2.6, _paint);
        case CheerShape.star:
          canvas.rotate(p.spin * t * math.pi * 0.5);
          canvas.drawPath(_fourPointStar(6.5, 1.9), _paint);
      }
      canvas.restore();
    }
  }

  /// 四角星：四条二次贝塞尔向内收，得到尖角而不是圆润的菱形。
  Path _fourPointStar(double outer, double inner) {
    final path = Path();
    for (var i = 0; i < 4; i++) {
      final tipAngle = i * math.pi / 2;
      final nextAngle = tipAngle + math.pi / 2;
      final tip = Offset(math.cos(tipAngle) * outer, math.sin(tipAngle) * outer);
      final next = Offset(math.cos(nextAngle) * outer, math.sin(nextAngle) * outer);
      final ctrlAngle = tipAngle + math.pi / 4;
      final ctrl = Offset(math.cos(ctrlAngle) * inner, math.sin(ctrlAngle) * inner);
      if (i == 0) {
        path.moveTo(tip.dx, tip.dy);
      }
      path.quadraticBezierTo(ctrl.dx, ctrl.dy, next.dx, next.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _BurstPainter oldDelegate) =>
      oldDelegate.origin != origin ||
      oldDelegate.baseAlpha != baseAlpha ||
      oldDelegate.particles != particles ||
      oldDelegate.palette != palette;
}
