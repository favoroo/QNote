import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 单子树内容切换显现过渡：当 [triggerKey] 变化时播放一次轻量淡入 + 微幅上移。
///
/// 与 [AnimatedSwitcher] 的区别：不双份挂载旧/新子树，适合统计图表、长列表（共用
/// 同一 [ScrollController]）等不适合同时存在两份实例的场景。
/// 在稳态下 `FadeTransition`（opacity=1）与 `SlideTransition`（offset=0）不产生额外图层，
/// 同时保持树结构恒定，不会重置子树的局部状态。
class MotionReveal extends StatefulWidget {
  const MotionReveal({
    super.key,
    required this.triggerKey,
    required this.child,
    this.duration = AppDurations.normal,
    this.beginOpacity = 0.45,
    this.beginOffsetY = 0.012,
    this.curve = AppCurves.emphasized,
  });

  /// 变化时重新触发显现动画的键值。
  final Object? triggerKey;

  final Widget child;
  final Duration duration;

  /// 起始不透明度（保留底影而不是从全透明开始，避免切换瞬间闪白）。
  final double beginOpacity;

  /// 起始垂直偏移（相对自身高度的比例）。
  final double beginOffsetY;

  final Curve curve;

  @override
  State<MotionReveal> createState() => _MotionRevealState();
}

class _MotionRevealState extends State<MotionReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late CurvedAnimation _curved;
  late Animation<double> _opacity;
  late Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration, value: 1.0);
    _initAnimations();
  }

  void _initAnimations() {
    _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    _opacity = Tween<double>(begin: widget.beginOpacity, end: 1.0).animate(_curved);
    _offset = Tween<Offset>(begin: Offset(0, widget.beginOffsetY), end: Offset.zero).animate(_curved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = AppMotion.reduce(context);
    _controller.duration = reduce ? Duration.zero : widget.duration;
    if (reduce && _controller.isAnimating) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant MotionReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = AppMotion.reduce(context) ? Duration.zero : widget.duration;
    }
    if (oldWidget.curve != widget.curve ||
        oldWidget.beginOpacity != widget.beginOpacity ||
        oldWidget.beginOffsetY != widget.beginOffsetY) {
      _curved.dispose();
      _initAnimations();
    }
    if (oldWidget.triggerKey != widget.triggerKey) {
      if (AppMotion.reduce(context)) {
        _controller.value = 1.0;
      } else {
        _controller.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(position: _offset, child: widget.child),
      ),
    );
  }
}

/// 首次挂载时播放一次「淡入 + 像素级上移归位」的轻量入场容器。
///
/// 采用原生 [FadeTransition] + 像素位移，避免用 [Opacity] Widget 在每帧申请离屏
/// `saveLayer`；同时在动画落定后保持同一层树结构，不会导致子树的滚动位置或图片状态丢失。
class MotionFadeSlideEntrance extends StatefulWidget {
  const MotionFadeSlideEntrance({
    super.key,
    required this.child,
    this.duration = AppDurations.fast,
    this.beginOffsetY = 8.0,
    this.curve = AppCurves.emphasized,
  });

  final Widget child;
  final Duration duration;

  /// 起始向下偏移的逻辑像素；动画结束归零。
  final double beginOffsetY;

  final Curve curve;

  @override
  State<MotionFadeSlideEntrance> createState() => _MotionFadeSlideEntranceState();
}

class _MotionFadeSlideEntranceState extends State<MotionFadeSlideEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    final disableAnimations = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    _controller = AnimationController(vsync: this, duration: widget.duration, value: disableAnimations ? 1.0 : 0.0);
    _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    if (!disableAnimations) {
      _controller.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = AppMotion.reduce(context);
    _controller.duration = reduce ? Duration.zero : widget.duration;
    if (reduce && _controller.value < 1.0) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant MotionFadeSlideEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = AppMotion.reduce(context) ? Duration.zero : widget.duration;
    }
    if (oldWidget.curve != widget.curve) {
      _curved.dispose();
      _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: AnimatedBuilder(
        animation: _curved,
        child: widget.child,
        builder: (context, child) {
          final dy = (1.0 - _curved.value) * widget.beginOffsetY;
          if (dy.abs() < 0.05) {
            return child!;
          }
          return Transform.translate(offset: Offset(0, dy), child: child);
        },
      ),
    );
  }
}
