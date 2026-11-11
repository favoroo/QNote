import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/statistics/stat_shared.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

Color _getRatingColor(String key) {
  switch (key) {
    case '健康':
      return const Color(0xFF10B981);
    case '一般':
      return const Color(0xFFF59E0B);
    case '不健康':
      return const Color(0xFFEF4444);
    case '过于放纵':
      return const Color(0xFF991B1B);
    default:
      return const Color(0xFF6B7280);
  }
}

class DietStatsWidget extends StatelessWidget {
  final DietStatistics stats;

  const DietStatsWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final healthData = stats.healthDistribution.entries.where((e) => e.value > 0).toList();

    return Column(
      children: [
        StatsCardPair(
          left: StatsCard(
            title: '记录餐次',
            value: '${stats.totalMeals}次',
            icon: Icons.restaurant,
            iconColor: Colors.orange,
          ),
          right: StatsCard(
            title: '健康餐次',
            value: '${stats.healthDistribution['健康'] ?? 0}次',
            icon: Icons.favorite,
            iconColor: const Color(0xFF10B981),
          ),
        ),
        const SizedBox(height: 16),
        if (healthData.isNotEmpty)
          StatCardShell(
            isDark: isDark,
            title: '健康评价',
            leading: StatIconChip(
              icon: Icons.favorite,
              color: const Color(0xFF10B981),
              backgroundColor: isDark ? const Color(0x3310B981) : const Color(0x1A10B981),
            ),
            child: StatPieChart(
              isDark: isDark,
              data: healthData,
              colorOf: (label, _) => _getRatingColor(label),
            ),
          ),
      ],
    );
  }
}
