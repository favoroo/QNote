import 'package:flutter/material.dart';

import 'app_curves.dart';
import 'app_durations.dart';

/// 全局动效入口。
///
/// 除时长/曲线令牌外，这里集中处理两件容易在各页面写漏的事：
/// 1. 系统「减弱动态效果」开启时把时长降为 0，让隐式动画直接落在终态；
/// 2. 状态切换统一使用「淡入 + 轻微缩放」的 [AnimatedSwitcher] 过渡，
///    避免各处默认的线性淡入淡出手感不一致。
abstract class AppMotion {
  /// 系统是否开启了「减弱动态效果」。
  static bool reduce(BuildContext context) => MediaQuery.disableAnimationsOf(context);

  /// 按系统动效偏好返回实际时长；减弱动效时返回 [Duration.zero]。
  static Duration duration(BuildContext context, Duration base) {
    return reduce(context) ? Duration.zero : base;
  }

  /// 统一的切换过渡：新内容淡入并轻微放大，旧内容快速淡出。
  ///
  /// [child] 需要带随状态变化的 `Key`，否则 [AnimatedSwitcher] 不会触发过渡。
  static Widget switcher({
    required BuildContext context,
    required Widget child,
    Duration baseDuration = AppDurations.fast,
    bool scale = true,
    Alignment alignment = Alignment.center,
  }) {
    return AnimatedSwitcher(
      duration: duration(context, baseDuration),
      switchInCurve: AppCurves.emphasized,
      switchOutCurve: AppCurves.exit,
      transitionBuilder: (child, animation) {
        final faded = FadeTransition(opacity: animation, child: child);
        if (!scale) {
          return faded;
        }
        return ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(animation),
          alignment: alignment,
          child: faded,
        );
      },
      child: child,
    );
  }
}
