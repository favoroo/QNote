import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/providers/navigation_provider.dart';

/// 顶栏「返回主界面」按钮在工具栏里占用的宽度（与 AppBar 动作按钮同尺寸）。
const double kDrawerHomeButtonWidth = 48;

/// 侧边栏内嵌作用域标记。
///
/// 侧边栏里的页面同时也能作为根路由单独全屏打开（例如 AI 页引导用户去「添加模型」、
/// 从「小Q设置」之外进入技能编辑）。只有真正挂在侧边栏内嵌 Navigator 之下时才该出现
/// 「返回主界面」按钮——根路由打开时点它没有任何侧边栏可收，所以 [SideDrawer] 在
/// 内嵌 Navigator 之上挂一份本标记，页面据此判断。
class DrawerNavScope extends InheritedWidget {
  const DrawerNavScope({super.key, required super.child});

  /// 当前页面是否挂在侧边栏内。
  static bool isInside(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DrawerNavScope>() != null;
  }

  @override
  bool updateShouldNotify(DrawerNavScope oldWidget) => false;
}

/// 顶栏「返回主界面」图标按钮：收起侧边栏回到主界面，只给图标不给文字。
///
/// 原来收起抽屉靠点它右侧的空白区域，窄屏改成满屏后没有空白可点，退出只能靠这个按钮；
/// 因此一级菜单头部与内嵌页面顶栏都提供它，任意层级一键回主界面。
class DrawerHomeButton extends StatelessWidget {
  /// 图标颜色；不传则跟随所在位置（AppBar 内跟随其 iconTheme）。
  final Color? color;

  /// 点击行为；不传则收起侧边栏。
  ///
  /// 以根路由整页打开的入口（见 [DrawerPageHomeLeading]）没有可收的抽屉，需要换成 pop。
  final VoidCallback? onPressed;

  const DrawerHomeButton({super.key, this.color, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.home_outlined),
      tooltip: '返回主界面',
      color: color,
      onPressed: onPressed ?? closeDrawerToHome,
    );
  }
}

/// 退出根路由整页（抽屉保持收起，停在主界面）。
void _popFullScreenPage(BuildContext context) {
  Navigator.of(context).maybePop();
}

/// 退出根路由整页并重新拉开抽屉，回到一级菜单（来时的位置）。
///
/// 整页打开时抽屉停在一级菜单就被收起，记忆里没有入口可还原，重开必然落在
/// 一级菜单，无需额外清记忆；pop 与 openDrawer 同时发起，整页淡出的同时抽屉
/// 滑入，过渡无缝。整页不可 pop（被单独冷启动）时静默不动，避免把抽屉盖在页面上。
void _popToDrawerMenu(BuildContext context) {
  final NavigatorState navigator = Navigator.of(context);
  if (!navigator.canPop()) return;
  navigator.pop();
  rootScaffoldKey.currentState?.openDrawer();
}

/// 以根路由整页打开的侧边栏入口（目前是「数据统计」）的顶栏返回区。
///
/// 这类页面从抽屉一级菜单整页打开，两个按钮去往不同目的地：
/// 「←」退出整页并重新拉开抽屉回一级菜单（见 [_popToDrawerMenu]），
/// 「⌂」退出整页停在主界面。
class DrawerPageHomeLeading extends StatelessWidget {
  const DrawerPageHomeLeading({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 与 [DrawerNavLeading] 同构：有上一级才显示返回箭头
        if (_canPop(context)) BackButton(onPressed: () => _popToDrawerMenu(context)),
        DrawerHomeButton(onPressed: () => _popFullScreenPage(context)),
      ],
    );
  }
}

/// [DrawerPageHomeLeading] 当前占用的宽度，交给 `AppBar.leadingWidth`。
///
/// （AppBar 默认的 56 放不下两个按钮，会把第二个挤出可视区。）
double drawerPageHomeLeadingWidth(BuildContext context) {
  return (_canPop(context) ? kToolbarHeight : 0) + kDrawerHomeButtonWidth;
}

/// 收起侧边栏回到主界面。
///
/// 走全局 Scaffold 的 `closeDrawer` 而不是 `Navigator.pop`：内嵌页面里 pop 掉的是内嵌
/// 页面栈（只是退回菜单），只有全局 key 才能保证「无论停在哪一层，都是回主界面」。
void closeDrawerToHome() {
  HapticFeedback.selectionClick();
  rootScaffoldKey.currentState?.closeDrawer();
}

/// 侧边栏内嵌页面顶栏左侧的导航组：返回上一级 +（在侧边栏内时）返回主界面。
///
/// 用法：
/// ```dart
/// AppBar(
///   leading: const DrawerNavLeading(),
///   leadingWidth: drawerNavLeadingWidth(context),
/// )
/// ```
/// 页面既可能在侧边栏内展示，也可能作为根路由全屏打开，两种情况下这段宽度不同，
/// 因此宽度必须由 [drawerNavLeadingWidth] 用同一个 context 算出来，交给 `leadingWidth`
/// （AppBar 默认的 56 放不下两个按钮，会把第二个挤出可视区）。
class DrawerNavLeading extends StatelessWidget {
  const DrawerNavLeading({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 与 AppBar 原本自动生成的 leading 一致：有上一级才显示返回箭头
        if (_canPop(context))
          const SizedBox(
            width: kToolbarHeight,
            child: Center(child: BackButton()),
          ),
        if (DrawerNavScope.isInside(context)) const DrawerHomeButton(),
      ],
    );
  }
}

/// [DrawerNavLeading] 当前占用的宽度，交给 `AppBar.leadingWidth`。
double drawerNavLeadingWidth(BuildContext context) {
  return (_canPop(context) ? kToolbarHeight : 0) + (DrawerNavScope.isInside(context) ? kDrawerHomeButtonWidth : 0);
}

/// 是否显示返回箭头：等价于 AppBar 自动 leading 的判断条件。
bool _canPop(BuildContext context) => ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
