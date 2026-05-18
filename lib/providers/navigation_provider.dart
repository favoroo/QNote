import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final GlobalKey<ScaffoldState> rootScaffoldKey = GlobalKey<ScaffoldState>();

final navigationIndexProvider = StateProvider<int>((ref) => 0);

final navigationItems = [
  const NavigationItem(
    path: '/diary',
    label: '日记',
    icon: Icons.book_outlined,
    activeIcon: Icons.book,
  ),
  const NavigationItem(
    path: '/notes',
    label: '笔记',
    icon: Icons.note_outlined,
    activeIcon: Icons.note,
  ),
  const NavigationItem(
    path: '/todo',
    label: '待办',
    icon: Icons.check_circle_outline,
    activeIcon: Icons.check_circle,
  ),
  const NavigationItem(
    path: '/ai',
    label: 'AI',
    icon: Icons.smart_toy_outlined,
    activeIcon: Icons.smart_toy,
  ),
  const NavigationItem(
    path: '/statistics',
    label: '统计',
    icon: Icons.bar_chart_outlined,
    activeIcon: Icons.bar_chart,
  ),
];

class NavigationItem {
  final String path;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const NavigationItem({
    required this.path,
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}
