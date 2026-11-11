import 'package:flutter/material.dart';

/// 统计卡片与日记列表共用的中性语义色板。
///
/// 这里只收敛「语义一致、深浅色成对」的中性色，且保留调用方原有的
/// ARGB 值。图表色板、评分色、标签分类色等业务专属颜色不进入本文件，
/// 避免把语义色板变成万能调色盘。
///
/// 注意：这些值并不总是与 [ColorScheme] 的同名字段一致（例如统计页的
/// 次要文字比 `onSurfaceVariant` 更深），因此调用方继续按 `isDark`
/// 取值，而不是改用 `Theme.of(context).colorScheme`，以保证视觉不变。
abstract class AppPalette {
  static const Color _lightTextPrimary = Color(0xFF191B23);
  static const Color _darkTextPrimary = Color(0xFFE2E2E9);

  static const Color _lightTextSecondary = Color(0xFF424754);
  static const Color _darkTextSecondary = Color(0xFFC2C6D6);

  static const Color _lightBorder = Color(0xFFC2C6D6);
  static const Color _darkBorder = Color(0x1A383C47);

  static const Color _lightChipBackground = Color(0xFFECEDF7);
  static const Color _darkChipBackground = Color(0xFF2A2D36);

  static const Color _lightChartGrid = Color(0xFFE4E4E7);
  static const Color _darkChartGrid = Color(0xFF2A2D36);

  /// 主要文字：卡片标题、关键数值。
  static Color textPrimary(bool isDark) => isDark ? _darkTextPrimary : _lightTextPrimary;

  /// 次要文字：图表分类标签、图例、列表副标题。
  static Color textSecondary(bool isDark) => isDark ? _darkTextSecondary : _lightTextSecondary;

  /// 弱化文字：坐标轴刻度、空态提示、次要计数。
  ///
  /// 深浅色下使用同一亮度，保持统计卡片内的信息层级一致。
  static const Color textMuted = Color(0xFF94A3B8);

  /// 卡片细描边。
  static Color border(bool isDark) => isDark ? _darkBorder : _lightBorder;

  /// 图标徽标等浅量填充底。
  static Color chipBackground(bool isDark) => isDark ? _darkChipBackground : _lightChipBackground;

  /// 进度条轨道底色。
  ///
  /// 当前与 [chipBackground] 共用同一组中性值，但语义独立，便于后续分别调整。
  static Color progressTrack(bool isDark) => isDark ? _darkChipBackground : _lightChipBackground;

  /// 图表水平网格线。
  static Color chartGrid(bool isDark) => isDark ? _darkChartGrid : _lightChartGrid;
}
