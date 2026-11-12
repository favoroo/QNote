import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final GlobalKey<ScaffoldState> rootScaffoldKey = GlobalKey<ScaffoldState>();

final navigationIndexProvider = StateProvider<int>((ref) => 0);

/// StatefulShellRoute 中各分支的固定索引。
///
/// 统计已移出底栏、改由抽屉全屏打开，分支只剩 4 条；中央小Q固定为最后一条。
abstract final class ShellBranch {
  static const int diary = 0;
  static const int notes = 1;
  static const int todo = 2;
  static const int ai = 3;
}

/// 「记录」合并入口的两个分段（笔记 / 待办）。
enum RecordsSection { notes, todo }

/// 底栏入口清单（不含中央小Q）。
///
/// 笔记与待办共用一个底部按钮，但仍是两条独立分支，索引与 [ShellBranch] 对齐。
final navigationItems = [
  const NavigationItem(path: '/diary', label: '时间线', icon: Icons.book_outlined, activeIcon: Icons.book),
  const NavigationItem(path: '/notes', label: '笔记', icon: Icons.note_outlined, activeIcon: Icons.note),
  const NavigationItem(path: '/todo', label: '待办', icon: Icons.check_circle_outline, activeIcon: Icons.check_circle),
];

class NavigationItem {
  final String path;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const NavigationItem({required this.path, required this.label, required this.icon, required this.activeIcon});
}
