import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

const _chartColors = [Color(0xFF6366F1), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEF4444), Color(0xFF8B5CF6)];

class DietStatsWidget extends StatelessWidget {
  final DietStatistics stats;

  const DietStatsWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final pieData = stats.typeDistribution.entries.toList();

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '累计饮水',
                value: '${stats.totalWaterIntake.toInt()}ml',
                icon: Icons.water_drop,
                iconColor: Colors.blue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '记录餐次',
                value: '${stats.totalMeals}次',
                icon: Icons.restaurant,
                iconColor: Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SectionCard(
          isDark: isDark,
          iconBgColor: isDark ? const Color(0x333B82F6) : const Color(0x1A3B82F6),
          iconColor: Colors.blue,
          icon: Icons.water_drop,
          title: '饮水量趋势',
          child: SizedBox(
            height: 192,
            child: stats.dailyWaterIntake.isNotEmpty
                ? _WaterBarChart(dailyWater: stats.dailyWaterIntake, isDark: isDark)
                : Center(child: Text('暂无数据', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)))),
          ),
        ),
        const SizedBox(height: 16),
        if (pieData.isNotEmpty)
          _SectionCard(
            isDark: isDark,
            iconBgColor: isDark ? const Color(0x33F59E0B) : const Color(0x1AF59E0B),
            iconColor: Colors.orange,
            icon: Icons.pie_chart,
            title: '饮食类型分布',
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

class _WaterBarChart extends StatelessWidget {
  final List<({String date, double amount})> dailyWater;
  final bool isDark;

  const _WaterBarChart({required this.dailyWater, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: isDark ? const Color(0xFF2A2D36) : const Color(0xFFE4E4E7),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= dailyWater.length) return const SizedBox.shrink();
                final parts = dailyWater[idx].date.split('-');
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${parts[1]}/${parts[2]}',
                    style: TextStyle(fontSize: 10, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: TextStyle(fontSize: 10, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
              ),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: dailyWater.asMap().entries.map((e) {
          return BarChartGroupData(
            x: e.key,
            barRods: [
              BarChartRodData(
                toY: e.value.amount,
                color: Colors.blue,
                width: dailyWater.length > 14 ? 8 : 16,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
