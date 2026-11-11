import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/utils/cheer_burst.dart';
import 'package:qnote_flutter/widgets/animated_gradient_border.dart';

/// 记完一次记录后的庆祝事件，由日记页的 listen 逻辑构造。
///
/// [id] 自增，用于区分连续两次内容完全相同的记录，避免动画被当成
/// 「无变化」吞掉。
class CheerEvent {
  const CheerEvent({required this.id, required this.title, this.sub, required this.level});

  final int id;
  final String title;
  final String? sub;

  /// 庆祝强度：满档与破纪录才配流光描边，普通记录保持极轻。
  final CheerLevel level;

  bool get isCheer => level.isCheer;
}

/// 输入条上方浮现的轻量庆祝胶囊。
///
/// 入场用弹性缩放 + 上浮，图标比胶囊本体晚一拍转进来，形成层次；达标与破纪录
/// 额外挂一圈流光描边和一次底色呼吸。退场由 [leaving] 驱动，播完通过
/// [onDismissed] 交回调用方移除，避免动画还没走完就被硬切掉。
class RecordCheerToast extends StatefulWidget {
  const RecordCheerToast({super.key, required this.event, this.leaving = false, this.onDismissed});

  final CheerEvent event;

  /// 调用方停留时间到点后置 true，本组件随即播退场。
  final bool leaving;

  /// 退场播完的回调，调用方在此把事件置空。
  final VoidCallback? onDismissed;

  @override
  State<RecordCheerToast> createState() => _RecordCheerToastState();
}

class _RecordCheerToastState extends State<RecordCheerToast> with SingleTickerProviderStateMixin {
  // 入场用 normal、退场用 fast：庆祝要「弹进来、利落地走」，两段不对称是故意的，
  // 直接用同一档位会让退场拖沓。
  static const Duration _entryDuration = AppDurations.normal;
  static const Duration _exitDuration = AppDurations.fast;

  /// 图标在入场进度轴上的起跳点（约 50ms / 200ms），比本体晚一拍。
  static const double _iconStartAt = 0.25;

  late final AnimationController _controller;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _entryDuration, reverseDuration: _exitDuration)
      ..addStatusListener(_onStatusChanged);
    if (widget.leaving) {
      _controller.value = 1;
      _startExit();
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(RecordCheerToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.event.id != oldWidget.event.id) {
      // 连记多条复用同一实例重播入场：重新挂载会让流光描边从头开始转，闪一下。
      _leaving = false;
      _controller.forward(from: 0);
    } else if (widget.leaving && !_leaving) {
      _startExit();
    }
  }

  void _startExit() {
    _leaving = true;
    _controller.reverse();
  }

  void _onStatusChanged(AnimationStatus status) {
    if (_leaving && status == AnimationStatus.dismissed) {
      widget.onDismissed?.call();
    }
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final event = widget.event;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // 入场走弹性曲线（末端会轻微过冲再落定），退场只按普通加速淡出。
        final curved = _leaving || reduceMotion ? _controller.value : AppCurves.spring.transform(_controller.value);
        final glow = _leaving || reduceMotion ? 0.0 : math.sin(_controller.value * math.pi);

        return Opacity(
          opacity: _fadeFor(reduceMotion),
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - curved)),
            child: Transform.scale(
              scale: 0.86 + 0.14 * curved,
              child: _Breathe(
                intensity: event.isCheer ? glow : 0,
                color: scheme.primary,
                child: _capsule(theme, scheme, event, _iconProgress(), reduceMotion),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 图标在自身进度轴上的位置：比胶囊本体晚约 60ms 起跳，错开才不糊成一团。
  double _iconProgress() {
    final t = (_controller.value - _iconStartAt) / (1 - _iconStartAt);
    return AppCurves.spring.transform(t.clamp(0.0, 1.0));
  }

  Widget _capsule(ThemeData theme, ColorScheme scheme, CheerEvent event, double iconT, bool reduceMotion) {
    final isDark = theme.brightness == Brightness.dark;
    // 深色主题的 inverseSurface 语义是「反色」，实际是近白色（#E2E2E9）。
    // 直接铺在胶囊上会在暗色页面里变成一块亮斑，所以深色下改用抬升一层的
    // 容器色：保留浮起的层级，但表面与文字都留在深色体系内。
    final background = isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface;
    final foreground = isDark ? scheme.onSurface : scheme.onInverseSurface;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      // 深色下底色与页面底只差一档，补一圈浅色细描边把胶囊边界交代清楚。
      side: isDark ? BorderSide(color: scheme.onSurface.withValues(alpha: 0.12)) : BorderSide.none,
    );

    return AnimatedGradientBorder(
      isAnimating: event.isCheer && !reduceMotion && !_leaving,
      borderRadius: 20,
      strokeWidth: 1.6,
      child: Material(
        elevation: 0,
        color: background,
        shape: shape,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: event.isCheer ? 16 : 14, vertical: event.isCheer ? 10 : 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CheerIcon(event: event, progress: iconT, color: isDark ? scheme.primary : scheme.inversePrimary),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: foreground),
                    ),
                    if (event.sub != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.sub!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: foreground.withValues(alpha: 0.75)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _fadeFor(bool reduceMotion) {
    if (reduceMotion) {
      return _controller.value;
    }
    return AppCurves.emphasized.transform(_controller.value);
  }
}

/// 一次底色呼吸：达标瞬间在胶囊背后浮出主题色柔光再收回。
///
/// 只用背景色与阴影表达，不额外加 Padding —— 呼吸若参与布局，胶囊宽度会随动画
/// 中途变化导致整块抖动。也不起循环动画：常驻 ticker 会让这块区域每帧脏重绘。
class _Breathe extends StatelessWidget {
  const _Breathe({required this.intensity, required this.color, this.child});

  final double intensity;
  final Color color;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (intensity <= 0) {
      return child ?? const SizedBox.shrink();
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07 * intensity),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.10 * intensity),
            blurRadius: 14,
            spreadRadius: 3 + 5 * intensity,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 庆祝图标：由父级传入自身进度，晚于胶囊本体转进 + 拍出。
///
/// 共用父级 controller 而不是自己再起一个：两条时间轴不同步会互相错乱。
class _CheerIcon extends StatelessWidget {
  const _CheerIcon({required this.event, required this.progress, required this.color});

  final CheerEvent event;
  final double progress;

  /// 由父级按深浅色挑好的前景色。
  ///
  /// 深色下不能用 inversePrimary：它在暗色主题里是深蓝（#0058BE），
  /// 落在深色胶囊上几乎没有对比度。
  final Color color;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      event.isCheer ? Icons.celebration_rounded : Icons.check_circle_rounded,
      size: event.isCheer ? 18 : 16,
      color: color,
    );
    if (progress >= 1) {
      return icon;
    }
    return Transform.rotate(
      // 从 -63° 转正，配合缩放才有「被甩出来」的感觉，单纯淡入太软。
      angle: -0.35 * math.pi * (1 - progress),
      child: Transform.scale(scale: 0.4 + 0.6 * progress, child: icon),
    );
  }
}
