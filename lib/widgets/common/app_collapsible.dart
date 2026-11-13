import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 通用「幕布式」展开/收起容器。
///
/// 与直接使用 [AnimatedSize] 的区别：
/// - 收起时父级通常已经把 child 换成占位，这里会保留收起前最后一份真实内容
///   继续播放退场，避免用户只看到一块留白高度在收缩；
/// - 动画真正结束后才卸载子级并释放缓存，折叠列表不会常驻构建隐藏内容；
/// - 展开略慢、收起更快，并统一遵循系统「减弱动态效果」。
class AppCollapsible extends StatefulWidget {
  const AppCollapsible({
    super.key,
    required this.expanded,
    required this.child,
    this.duration = AppDurations.normal,
    this.reverseDuration = AppDurations.fast,
    this.sizeCurve = AppCurves.emphasizedSpatial,
    this.reverseSizeCurve = AppCurves.exit,
    this.fadeInInterval = const Interval(0.1, 0.72, curve: Curves.easeOut),
    this.fadeOutInterval = const Interval(0.32, 1, curve: Curves.easeIn),
    this.rise = 6,
  });

  /// 是否展开。
  final bool expanded;

  /// 展开时的内容；收起后可以传占位，组件会自行保留上一份内容播放退场。
  final Widget child;

  /// 展开时长。
  final Duration duration;

  /// 收起时长（默认比展开快，避免拖住下一步操作）。
  final Duration reverseDuration;

  final Curve sizeCurve;
  final Curve reverseSizeCurve;

  /// 内容淡入区间：比高度略早完成，避免内容贴着收缩边界消失。
  final Interval fadeInInterval;

  /// 内容淡出区间：先淡出再收拢，不留一条悬空内容。
  final Interval fadeOutInterval;

  /// 入场时内容额外上移的像素；0 表示只做淡入（列表行内使用）。
  final double rise;

  @override
  State<AppCollapsible> createState() => _AppCollapsibleState();
}

class _AppCollapsibleState extends State<AppCollapsible> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _opacity;
  late final Animation<double> _riseAnimation;

  /// 动画期间子级仍需挂载，收起结束后才卸载。
  bool _visible = false;

  /// 收起时父级已把 child 换成占位，这里保留最后一份真实内容继续播放退场。
  Widget? _retainedChild;

  @override
  void initState() {
    super.initState();
    _visible = widget.expanded;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.reverseDuration,
      value: widget.expanded ? 1 : 0,
    );
    _sizeFactor = CurvedAnimation(parent: _controller, curve: widget.sizeCurve, reverseCurve: widget.reverseSizeCurve);
    _opacity = CurvedAnimation(parent: _controller, curve: widget.fadeInInterval, reverseCurve: widget.fadeOutInterval);
    _riseAnimation = CurvedAnimation(parent: _controller, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = AppMotion.reduce(context);
    _controller.duration = reduce ? Duration.zero : widget.duration;
    _controller.reverseDuration = reduce ? Duration.zero : widget.reverseDuration;
    // 动画途中打开系统减弱动效：直接落到终态，不残留半截高度
    if (reduce && _controller.isAnimating) {
      _controller.stop();
      _controller.value = widget.expanded ? 1 : 0;
      _visible = widget.expanded;
      _retainedChild = null;
    }
  }

  @override
  void didUpdateWidget(covariant AppCollapsible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;

    // 系统「减弱动态效果」开启时直接落到终态
    if (AppMotion.reduce(context)) {
      _controller.stop();
      _controller.value = widget.expanded ? 1 : 0;
      _visible = widget.expanded;
      _retainedChild = null;
      return;
    }

    if (widget.expanded) {
      // 展开中途被打断：父级这一帧已提供真实内容，直接接管并继续展开
      _retainedChild = null;
      _visible = true;
      _controller.forward();
    } else {
      _retainedChild = oldWidget.child;
      _controller.reverse().whenComplete(() {
        // 反向被新的展开打断时 value 不会归零，此时不能卸载子级
        if (!mounted || widget.expanded || _controller.value > 0) return;
        setState(() {
          _visible = false;
          _retainedChild = null;
        });
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) {
      return const SizedBox.shrink();
    }

    // 完全展开且动画已结束时直接返回内容：常驻列表行不必一直背着三层过渡包装
    if (widget.expanded && !_controller.isAnimating && _controller.value >= 1.0) {
      return widget.child;
    }

    final child = _retainedChild ?? widget.child;
    return SizeTransition(
      sizeFactor: _sizeFactor,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _opacity,
        child: widget.rise > 0
            ? AnimatedBuilder(
                animation: _riseAnimation,
                builder: (context, child) {
                  // 固定像素位移而不是按高度百分比：深层大子树也不会被放大成夸张滑动
                  return Transform.translate(
                    offset: Offset(0, -widget.rise * (1 - _riseAnimation.value)),
                    child: child,
                  );
                },
                child: child,
              )
            : child,
      ),
    );
  }
}
