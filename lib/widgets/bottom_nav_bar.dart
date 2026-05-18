import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';

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
    final theme = Theme.of(context);
    
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: navigationItems.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              final isSelected = index == currentIndex;

              return GestureDetector(
                onTap: () => onTap(index),
                onLongPress: index == 0
                    ? () {
                        // Switch to diary branch if not already selected
                        if (!isSelected) {
                          onTap(0);
                        }
                        // Trigger smooth scroll to current time in timeline
                        ref.read(diaryScrollTriggerProvider.notifier).state =
                            DateTime.now().millisecondsSinceEpoch;
                      }
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? theme.colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(
                    isSelected ? item.activeIcon : item.icon,
                    color: isSelected 
                        ? theme.colorScheme.primary 
                        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    size: 24,
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
