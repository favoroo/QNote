import 'package:flutter/material.dart';

/// 输出类型图标映射（注册表保持纯 Dart，图标只在 UI 层映射）。
///
/// 「+」面板卡片与输入区胶囊共用同一套映射，新增/删除类型时只需改这里，
/// 避免两处图标风格走散。
IconData iconForOutputType(String id) => switch (id) {
  'flowchart' => Icons.account_tree_outlined,
  'sequence' => Icons.swap_horiz_rounded,
  'gantt' => Icons.view_timeline_outlined,
  'mindmap' => Icons.hub_outlined,
  'er' => Icons.schema_outlined,
  'table' => Icons.table_chart_outlined,
  'json' => Icons.data_object_outlined,
  'chart' => Icons.insert_chart_outlined,
  'web' => Icons.language_rounded,
  'note' => Icons.description_outlined,
  _ => Icons.auto_awesome_outlined,
};
