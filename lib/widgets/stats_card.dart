import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/widgets/statistics/stat_shared.dart';

/// 统计数值卡片：展示标题、图标与单个数值。
class StatsCard extends StatelessWidget {
  /// 指标标题。
  final String title;

  /// 指标数值。
  final String value;

  /// 指标图标。
  final IconData icon;

  /// 图标颜色。
  final Color iconColor;

  const StatsCard({super.key, required this.title, required this.value, required this.icon, required this.iconColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return StatCardContainer(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: AppPalette.textMuted,
                  letterSpacing: 0.5,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppPalette.chipBackground(isDark),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 14, color: iconColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppPalette.textPrimary(isDark)),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
