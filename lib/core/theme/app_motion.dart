import 'package:flutter/material.dart';

import 'app_curves.dart';
import 'app_durations.dart';

/// 全局动效入口。
///
/// 除时长/曲线令牌外，这里集中处理几件容易在各页面写漏的事：
/// 1. 系统「减弱动态效果」开启时把时长降为 0，让隐式动画直接落在终态；
/// 2. 状态切换统一使用「淡入 + 轻微缩放」的 [AnimatedSwitcher] 过渡；
/// 3. 程序化滚动/翻页在零时长下改走瞬跳，避免 `animateTo` 触发零时长断言；
/// 4. 弹窗与全屏图库/次级路由提供统一样式的进退场过渡。
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

  /// 安全执行程序化滚动：开启「减弱动态效果」时直接瞬跳，避免传 `Duration.zero` 触发断言。
  static Future<void> animateScrollTo(
    ScrollController controller,
    double offset, {
    required BuildContext context,
    Duration baseDuration = AppDurations.medium,
    Curve curve = AppCurves.emphasized,
  }) async {
    if (!controller.hasClients) {
      return;
    }
    final resolvedDuration = duration(context, baseDuration);
    if (resolvedDuration == Duration.zero) {
      controller.jumpTo(offset);
      return;
    }
    await controller.animateTo(offset, duration: resolvedDuration, curve: curve);
  }

  /// 安全执行分页跳转：开启「减弱动态效果」时直接瞬跳，避免传 `Duration.zero` 触发断言。
  static Future<void> animateToPage(
    PageController controller,
    int page, {
    required BuildContext context,
    Duration baseDuration = AppDurations.medium,
    Curve curve = AppCurves.emphasized,
  }) async {
    if (!controller.hasClients) {
      return;
    }
    final resolvedDuration = duration(context, baseDuration);
    if (resolvedDuration == Duration.zero) {
      controller.jumpToPage(page);
      return;
    }
    await controller.animateToPage(page, duration: resolvedDuration, curve: curve);
  }

  /// 次级路由统一的淡入 + 轻微上移过渡（由状态化包装器缓存曲线，避免每帧重复分配）。
  static Widget buildFadeSlideTransition({
    required BuildContext context,
    required Animation<double> animation,
    required Widget child,
    double beginOffsetY = 0.02,
  }) {
    if (reduce(context)) {
      return child;
    }
    return _MotionFadeSlideTransition(animation: animation, beginOffsetY: beginOffsetY, child: child);
  }

  /// 构造与 GoRouter 二级页面一致手感的 [PageRoute]。
  static PageRoute<T> fadeRoute<T>(Widget page, {bool fullscreenDialog = false, RouteSettings? settings}) {
    return PageRouteBuilder<T>(
      settings: settings,
      fullscreenDialog: fullscreenDialog,
      transitionDuration: AppDurations.page,
      reverseTransitionDuration: AppDurations.normal,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return buildFadeSlideTransition(context: context, animation: animation, child: child);
      },
    );
  }

  /// 构造大图浏览页面的暗底淡入轻缩放路由。
  static PageRoute<T> galleryRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: AppDurations.normal,
      reverseTransitionDuration: AppDurations.fast,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (reduce(context)) {
          return child;
        }
        return _MotionScaleFadeTransition(animation: animation, beginScale: 0.95, child: child);
      },
    );
  }

  /// 统一居中弹窗：强调缩放（0.94 -> 1.0）+ 淡入、快速加速退场，并遵循减弱动效设置。
  ///
  /// 底层沿用 [RawDialogRoute] 继承 [PopupRoute]，保证全局悬浮小Q 模态遮蔽计数与原生弹窗一致。
  static Future<T?> showDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    Color? barrierColor,
    String? barrierLabel,
    bool useSafeArea = true,
    bool useRootNavigator = true,
    RouteSettings? routeSettings,
    Offset? anchorPoint,
    TraversalEdgeBehavior? traversalEdgeBehavior,
    bool requestFocus = true,
  }) {
    final themes = InheritedTheme.capture(
      from: context,
      to: Navigator.of(context, rootNavigator: useRootNavigator).context,
    );
    final reduced = reduce(context);
    final resolvedBarrierColor = barrierColor ?? Colors.black54;
    final resolvedBarrierLabel = barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel;

    return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
      _AppDialogRoute<T>(
        transitionDuration: reduced ? Duration.zero : AppDurations.normal,
        reverseTransitionDuration: reduced ? Duration.zero : AppDurations.fast,
        barrierDismissible: barrierDismissible,
        barrierColor: resolvedBarrierColor,
        barrierLabel: resolvedBarrierLabel,
        settings: routeSettings,
        anchorPoint: anchorPoint,
        traversalEdgeBehavior: traversalEdgeBehavior,
        requestFocus: requestFocus,
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          final Widget dialog = Builder(builder: builder);
          return themes.wrap(useSafeArea ? SafeArea(child: dialog) : dialog);
        },
        transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
          if (reduce(dialogContext)) {
            return child;
          }
          return _MotionScaleFadeTransition(animation: animation, beginScale: 0.94, child: child);
        },
      ),
    );
  }
}

/// 继承 [RawDialogRoute] 以支持与入场解耦的更快退场时长。
class _AppDialogRoute<T> extends RawDialogRoute<T> {
  _AppDialogRoute({
    required super.pageBuilder,
    required super.transitionDuration,
    required Duration reverseTransitionDuration,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.transitionBuilder,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.requestFocus,
  }) : _reverseTransitionDuration = reverseTransitionDuration;

  final Duration _reverseTransitionDuration;

  @override
  Duration get reverseTransitionDuration => _reverseTransitionDuration;
}

/// 缓存并释放 [CurvedAnimation] 的淡入 + 位移过渡，避免 `transitionsBuilder` 每帧重建实例。
class _MotionFadeSlideTransition extends StatefulWidget {
  const _MotionFadeSlideTransition({required this.animation, required this.beginOffsetY, required this.child});

  final Animation<double> animation;
  final double beginOffsetY;
  final Widget child;

  @override
  State<_MotionFadeSlideTransition> createState() => _MotionFadeSlideTransitionState();
}

class _MotionFadeSlideTransitionState extends State<_MotionFadeSlideTransition> {
  late CurvedAnimation _curved;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _initAnimations();
  }

  void _initAnimations() {
    _curved = CurvedAnimation(parent: widget.animation, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
    _slide = Tween<Offset>(begin: Offset(0, widget.beginOffsetY), end: Offset.zero).animate(_curved);
  }

  @override
  void didUpdateWidget(covariant _MotionFadeSlideTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation || oldWidget.beginOffsetY != widget.beginOffsetY) {
      _curved.dispose();
      _initAnimations();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// 缓存并释放 [CurvedAnimation] 的强调缩放 + 淡入过渡（用于弹窗与大图画廊）。
class _MotionScaleFadeTransition extends StatefulWidget {
  const _MotionScaleFadeTransition({required this.animation, required this.beginScale, required this.child});

  final Animation<double> animation;
  final double beginScale;
  final Widget child;

  @override
  State<_MotionScaleFadeTransition> createState() => _MotionScaleFadeTransitionState();
}

class _MotionScaleFadeTransitionState extends State<_MotionScaleFadeTransition> {
  late CurvedAnimation _curved;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _initAnimations();
  }

  void _initAnimations() {
    _curved = CurvedAnimation(parent: widget.animation, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
    _scale = Tween<double>(begin: widget.beginScale, end: 1.0).animate(_curved);
  }

  @override
  void didUpdateWidget(covariant _MotionScaleFadeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation || oldWidget.beginScale != widget.beginScale) {
      _curved.dispose();
      _initAnimations();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
