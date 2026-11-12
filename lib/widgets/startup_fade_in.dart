import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 冷启动首帧的交叉淡入。
///
/// 原生启动窗口（Android `LaunchTheme` / iOS `LaunchScreen`）消失到 Flutter 首帧
/// 接管之间，是两个独立绘制系统在交接：即使两边底色已经对齐到同一画布色，
/// 个别机型仍会因为合成器时序出现一帧硬切。这里让 App 内容从透明淡入到不透明，
/// 交接期间透出的正是原生窗口底色，于是过渡变成「同一颜色里内容浮现」。
///
/// 只跑一次：动画结束就彻底移除这层 [FadeTransition]，后续滚动、切页、
/// 主题切换都不再经过额外的透明度图层。
class StartupFadeIn extends StatefulWidget {
  const StartupFadeIn({super.key, required this.child});

  final Widget child;

  /// 首帧淡入时长。比 [AppDurations.normal] 略长：这段动画期间用户还没开始操作，
  /// 稍慢一点更不容易被察觉成「闪一下」。
  static const Duration duration = Duration(milliseconds: 260);

  @override
  State<StartupFadeIn> createState() => _StartupFadeInState();
}

class _StartupFadeInState extends State<StartupFadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: StartupFadeIn.duration);

  /// 动画结束后置为 true：把 [FadeTransition] 从树上摘掉，恢复零额外图层的常态渲染。
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    // 从 0.94 起步而不是全透明：首帧内容本来就已经是终态，从纯透明开始会让
    // 用户先看到一段「空屏」；只差最后 6% 的透明度，观感上是一次极轻的浮现。
    _controller.value = 0.94;
    _controller.forward().whenComplete(() {
      if (mounted) {
        setState(() => _finished = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统开启减弱动效：直接落在终态，不做透明度过渡
    if (AppMotion.reduce(context) && _controller.value != 1.0) {
      _controller.value = 1.0;
      _finished = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) {
      return widget.child;
    }
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: AppCurves.emphasized),
      child: widget.child,
    );
  }
}
