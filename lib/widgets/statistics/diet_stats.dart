import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

const _chartColors = [Color(0xFF6366F1), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEF4444), Color(0xFF8B5CF6)];
const _ratingColors = [Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEF4444)];

class DietStatsWidget extends StatelessWidget {
  final DietStatistics stats;

  const DietStatsWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final pieData = stats.typeDistribution.entries.toList();
    final healthData = stats.healthDistribution.entries.where((e) => e.value > 0).toList();

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '记录餐次',
                value: '${stats.totalMeals}次',
                icon: Icons.restaurant,
                iconColor: Colors.orange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '记录总数',
                value: '${stats.typeDistribution.values.fold(0, (a, b) => a + b)}条',
                icon: Icons.fastfood,
                iconColor: Colors.blue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (pieData.isNotEmpty)
          _SectionCard(
            isDark: isDark,
            iconBgColor: isDark ? const Color(0x33F59E0B) : const Color(0x1AF59E0B),
            iconColor: Colors.orange,
            icon: Icons.pie_chart,
            title: '饮食类别分布',
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: PieChart(
                    PieChartData(
                      sections: pieData.asMap().entries.map((e) {
                        final color = _chartColors[e.key % _chartColors.length];
                        return PieChartSectionData(
                          value: e.value.value.toDouble(),
                          color: color,
                          radius: 60,
                          title: '${e.value.value}',
                          titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                        );
                      }).toList(),
                      sectionsSpace: 2,
                      centerSpaceRadius: 28,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: pieData.asMap().entries.map((e) {
                    final color = _chartColors[e.key % _chartColors.length];
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(
                          '${e.value.key} (${e.value.value})',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isDark ? const Color(0xFFC2C6D6) : const Color(0xFF424754),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (healthData.isNotEmpty)
          _SectionCard(
            isDark: isDark,
            iconBgColor: isDark ? const Color(0x3310B981) : const Color(0x1A10B981),
            iconColor: const Color(0xFF10B981),
            icon: Icons.favorite,
            title: '饮食健康评价',
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: PieChart(
                    PieChartData(
                      sections: healthData.asMap().entries.map((e) {
                        final healthKey = e.value.key;
                        final colorIndex = healthKey == '健康' ? 0 : (healthKey == '一般' ? 1 : 2);
                        final color = _ratingColors[colorIndex];
                        return PieChartSectionData(
                          value: e.value.value.toDouble(),
                          color: color,
                          radius: 60,
                          title: '${e.value.value}',
                          titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                        );
                      }).toList(),
                      sectionsSpace: 2,
                      centerSpaceRadius: 28,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: healthData.asMap().entries.map((e) {
                    final healthKey = e.value.key;
                    final colorIndex = healthKey == '健康' ? 0 : (healthKey == '一般' ? 1 : 2);
                    final color = _ratingColors[colorIndex];
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(
                          '${e.value.key} (${e.value.value})',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isDark ? const Color(0xFFC2C6D6) : const Color(0xFF424754),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final bool isDark;
  final Color iconBgColor;
  final Color iconColor;
  final IconData icon;
  final String title;
  final Widget child;

  const _SectionCard({
    required this.isDark,
    required this.iconBgColor,
    required this.iconColor,
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDark ? const Color(0x1A383C47) : const Color(0xFFC2C6D6),
          width: 0.5,
        ),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: iconBgColor, borderRadius: BorderRadius.circular(8)),
                  child: Icon(icon, size: 16, color: iconColor),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFFE2E2E9) : const Color(0xFF191B23),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
