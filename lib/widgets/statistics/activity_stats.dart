import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

const _activityColors = [Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFFF43F5E), Color(0xFF3B82F6), Color(0xFF10B981)];

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
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '活跃次数',
                value: '${stats.totalActivities}次',
                icon: Icons.bolt,
                iconColor: Colors.purple,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '总时长',
                value: '${stats.totalDuration.toStringAsFixed(stats.totalDuration == stats.totalDuration.toInt() ? 0 : 1)}小时',
                icon: Icons.schedule,
                iconColor: Colors.blue,
              ),
            ),
          ],
        ),
        if (stats.averageDuration > 0) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: StatsCard(
                  title: '平均时长',
                  value: '${stats.averageDuration.toStringAsFixed(stats.averageDuration == stats.averageDuration.toInt() ? 0 : 1)}小时',
                  icon: Icons.timer,
                  iconColor: Colors.orange,
                ),
              ),
              Expanded(
                child: StatsCard(
                  title: '活动类型',
                  value: '${pieData.length}种',
                  icon: Icons.track_changes,
                  iconColor: Colors.green,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _ActivityCard(
          isDark: isDark,
          title: '活跃度趋势',
          trailing: const SizedBox.shrink(),
          child: SizedBox(
            height: 192,
            child: stats.dailyData.isNotEmpty
                ? _ActivityBarChart(dailyData: stats.dailyData, isDark: isDark)
                : Center(child: Text('暂无数据', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)))),
          ),
        ),
        const SizedBox(height: 16),
        if (pieData.isNotEmpty)
          _ActivityCard(
            isDark: isDark,
            title: '活动类型分布',
            trailing: const SizedBox.shrink(),
            child: Column(
              children: [
                SizedBox(
                  height: 200,
                  child: PieChart(
                    PieChartData(
                      sections: pieData.asMap().entries.map((e) {
                        final color = _activityColors[e.key % _activityColors.length];
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
                    final color = _activityColors[e.key % _activityColors.length];
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
        if (durationData.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ActivityCard(
            isDark: isDark,
            title: '各类别时长',
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

class _ActivityCard extends StatelessWidget {
  final bool isDark;
  final String title;
  final Widget trailing;
  final Widget child;

  const _ActivityCard({required this.isDark, required this.title, required this.trailing, required this.child});

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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFFE2E2E9) : const Color(0xFF191B23),
                  ),
                ),
                trailing,
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
                if (idx < 0 || idx >= dailyData.length) return const SizedBox.shrink();
                final parts = dailyData[idx].date.split('-');
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
              reservedSize: 30,
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
                if (idx < 0 || idx >= durationData.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    durationData[idx].key,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFC2C6D6) : const Color(0xFF424754)),
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
