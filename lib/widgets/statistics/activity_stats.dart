import 'package:flutter/material.dart';

import 'package:fl_chart/fl_chart.dart';

import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/statistics/stat_shared.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

const _activityColors = [Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFFF43F5E), Color(0xFF3B82F6), Color(0xFF10B981)];

/// 将小时数格式化为整数或一位小数的展示文本。
String _formatHours(double value) {
  final fractionDigits = value == value.toInt() ? 0 : 1;
  return '${value.toStringAsFixed(fractionDigits)}小时';
}

class ActivityStatsWidget extends StatelessWidget {
  final ActivityStatistics stats;

  const ActivityStatsWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final pieData = stats.typeDistribution.entries.toList();
    final durationData = stats.durationByType.entries.toList();

    return Column(
      children: [
        StatsCardPair(
          left: StatsCard(
            title: '活跃次数',
            value: '${stats.totalActivities}次',
            icon: Icons.bolt,
            iconColor: Colors.purple,
          ),
          right: StatsCard(
            title: '总时长',
            value: _formatHours(stats.totalDuration),
            icon: Icons.schedule,
            iconColor: Colors.blue,
          ),
        ),
        if (stats.averageDuration > 0) ...[
          const SizedBox(height: 12),
          StatsCardPair(
            left: StatsCard(
              title: '平均时长',
              value: _formatHours(stats.averageDuration),
              icon: Icons.timer,
              iconColor: Colors.orange,
            ),
            right: StatsCard(
              title: '活动类型',
              value: '${pieData.length}种',
              icon: Icons.track_changes,
              iconColor: Colors.green,
            ),
            // 原布局该行两卡之间无间距，保持视觉不变
            gap: 0,
          ),
        ],
        const SizedBox(height: 16),
        StatCardShell(
          isDark: isDark,
          title: '活跃趋势',
          trailing: const SizedBox.shrink(),
          child: StatChartBox(
            height: 192,
            isEmpty: stats.dailyData.isEmpty,
            child: _ActivityBarChart(dailyData: stats.dailyData, isDark: isDark),
          ),
        ),
        const SizedBox(height: 16),
        if (pieData.isNotEmpty)
          StatCardShell(
            isDark: isDark,
            title: '类型分布',
            trailing: const SizedBox.shrink(),
            child: StatPieChart(
              isDark: isDark,
              data: pieData,
              colorOf: (_, index) => _activityColors[index % _activityColors.length],
            ),
          ),
        if (durationData.isNotEmpty) ...[
          const SizedBox(height: 16),
          StatCardShell(
            isDark: isDark,
            title: '分类时长',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isDark ? const Color(0x338B5CF6) : const Color(0x1A8B5CF6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '小时',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isDark ? const Color(0xFFC4B5FD) : Colors.purple,
                ),
              ),
            ),
            child: SizedBox(
              height: 192,
              child: _DurationBarChart(durationData: durationData, isDark: isDark),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActivityBarChart extends StatelessWidget {
  final List<({String date, int count})> dailyData;
  final bool isDark;

  const _ActivityBarChart({required this.dailyData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(color: AppPalette.chartGrid(isDark), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= dailyData.length) return const SizedBox.shrink();
                final parts = dailyData[idx].date.split('-');
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${parts[1]}/${parts[2]}',
                    style: const TextStyle(fontSize: 10, color: AppPalette.textMuted),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (value, meta) =>
                  Text('${value.toInt()}', style: const TextStyle(fontSize: 10, color: AppPalette.textMuted)),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: dailyData.asMap().entries.map((e) {
          return BarChartGroupData(
            x: e.key,
            barRods: [
              BarChartRodData(
                toY: e.value.count.toDouble(),
                color: Colors.purple,
                width: dailyData.length > 14 ? 8 : 16,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _DurationBarChart extends StatelessWidget {
  final List<MapEntry<String, double>> durationData;
  final bool isDark;

  const _DurationBarChart({required this.durationData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(color: AppPalette.chartGrid(isDark), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= durationData.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    durationData[idx].key,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: AppPalette.textSecondary(isDark),
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) =>
                  Text('${value.toInt()}', style: const TextStyle(fontSize: 10, color: AppPalette.textMuted)),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        barGroups: durationData.asMap().entries.map((e) {
          final color = _activityColors[e.key % _activityColors.length];
          return BarChartGroupData(
            x: e.key,
            barRods: [
              BarChartRodData(
                toY: e.value.value,
                color: color,
                width: 32,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
