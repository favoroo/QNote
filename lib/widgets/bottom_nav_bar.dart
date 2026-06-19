import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
      body: widget.navigationShell,
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
            child: Icon(item.activeIcon),
          ),
          label: item.label,
        );
      }).toList(),
    );
  }
}
