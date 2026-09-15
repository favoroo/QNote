import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';
import 'package:qnote_flutter/widgets/debug_console.dart';

class ScaffoldWithNavBar extends StatefulWidget {
  final StatefulNavigationShell navigationShell;

  const ScaffoldWithNavBar({super.key, required this.navigationShell});

  @override
  State<ScaffoldWithNavBar> createState() => _ScaffoldWithNavBarState();
}

class _ScaffoldWithNavBarState extends State<ScaffoldWithNavBar> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: rootScaffoldKey,
      drawer: const SideDrawer(),
      body: _NavBranchTransition(
        currentIndex: widget.navigationShell.currentIndex,
        child: widget.navigationShell,
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: widget.navigationShell.currentIndex,
        onTap: (index) {
          widget.navigationShell.goBranch(
            index,
            initialLocation: index == widget.navigationShell.currentIndex,
          );
        },
        onMenuTap: () => rootScaffoldKey.currentState?.openDrawer(),
      ),
    );
  }
}

/// 主导航分支切换平滑过渡组件。
///
/// 保持内部 navigationShell 不被重建，仅在其外层施加一次轻量淡入与微小位移动画，
/// 避免 tab 切换时的生硬瞬切，同时几乎不产生额外渲染负担。
class _NavBranchTransition extends StatefulWidget {
  final int currentIndex;
  final Widget child;

  const _NavBranchTransition({
    required this.currentIndex,
    required this.child,
  });

  @override
  State<_NavBranchTransition> createState() => _NavBranchTransitionState();
}

class _NavBranchTransitionState extends State<_NavBranchTransition>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  int _lastIndex = 0;

  @override
  void initState() {
    super.initState();
    _lastIndex = widget.currentIndex;
    _controller = AnimationController(
      vsync: this,
      duration: AppDurations.normal,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: AppCurves.emphasized,
    );
    _slideAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(_controller);
    // 首次展示直接到达最终态
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _NavBranchTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      // 判定切换方向：向右切（index变大）新页面由右向左微移，反之由左向右微移
      final direction = widget.currentIndex > _lastIndex ? 0.03 : -0.03;
      _lastIndex = widget.currentIndex;

      _slideAnimation = Tween<Offset>(
        begin: Offset(direction, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _controller,
        curve: AppCurves.emphasized,
      ));

      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: widget.child,
      ),
    );
  }
}

class BottomNavBar extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback? onMenuTap;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.onMenuTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NavigationBar(
      height: 60,
      selectedIndex: currentIndex,
      onDestinationSelected: (index) {
        HapticFeedback.selectionClick();
        onTap(index);
      },
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      destinations: navigationItems.asMap().entries.map((entry) {
        final index = entry.key;
        final item = entry.value;
        final isSelected = index == currentIndex;

        return NavigationDestination(
          icon: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPress: index == 0
                ? () {
                    if (!isSelected) {
                      onTap(0);
                    }
                    ref.read(diaryScrollTriggerProvider.notifier).state =
                        DateTime.now().millisecondsSinceEpoch;
                  }
                : (index == 2 ? () => showDebugConsole(context) : null),
            // 双击也跳转到当前时间，比长按更跟手
            onDoubleTap: index == 0
                ? () {
                    if (!isSelected) {
                      onTap(0);
                    }
                    ref.read(diaryScrollTriggerProvider.notifier).state =
                        DateTime.now().millisecondsSinceEpoch;
                  }
                : null,
            child: Icon(item.icon),
          ),
          selectedIcon: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPress: index == 0
                ? () {
                    ref.read(diaryScrollTriggerProvider.notifier).state =
                        DateTime.now().millisecondsSinceEpoch;
                  }
                : (index == 2 ? () => showDebugConsole(context) : null),
            onDoubleTap: index == 0
                ? () {
                    ref.read(diaryScrollTriggerProvider.notifier).state =
                        DateTime.now().millisecondsSinceEpoch;
                  }
                : null,
            child: Icon(item.activeIcon),
          ),
          label: item.label,
        );
      }).toList(),
    );
  }
}
