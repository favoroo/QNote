import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

class SleepStatsWidget extends StatelessWidget {
  final SleepStatistics stats;

  const SleepStatsWidget({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    String qualityLabel;
    if (stats.qualityDistribution['极好']! > 0) {
      qualityLabel = '极好为主';
    } else if (stats.qualityDistribution['良好']! > 0) {
      qualityLabel = '良好为主';
    } else {
      qualityLabel = '一般';
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '平均时长',
                value: '${stats.averageDuration.toStringAsFixed(1)}h',
                icon: Icons.schedule,
                iconColor: Colors.indigo,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '质量分布',
                value: qualityLabel,
                icon: Icons.emoji_events,
                iconColor: Colors.amber,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _ChartCard(
          isDark: isDark,
          iconBgColor: isDark ? const Color(0x336366F1) : const Color(0x1A6366F1),
          iconColor: Colors.indigo,
          icon: Icons.nightlight,
          title: '睡眠时长趋势',
          child: SizedBox(
            height: 192,
            child: stats.dailyData.isNotEmpty
                ? _SleepDurationChart(dailyData: stats.dailyData, isDark: isDark)
                : Center(child: Text('暂无数据', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)))),
          ),
        ),
        const SizedBox(height: 16),
        _ChartCard(
          isDark: isDark,
          iconBgColor: isDark ? const Color(0x33F59E0B) : const Color(0x1AF59E0B),
          iconColor: Colors.amber,
          icon: Icons.star,
          title: '质量统计',
          child: _QualityDistribution(
            qualityDistribution: stats.qualityDistribution,
            totalRecords: stats.totalRecords,
            isDark: isDark,
          ),
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  final bool isDark;
  final Color iconBgColor;
  final Color iconColor;
  final IconData icon;
  final String title;
  final Widget child;

  const _ChartCard({
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
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
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

class _SleepDurationChart extends StatelessWidget {
  final List<SleepDailyData> dailyData;
  final bool isDark;

  const _SleepDurationChart({required this.dailyData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < dailyData.length; i++) {
      spots.add(FlSpot(i.toDouble(), dailyData[i].duration));
    }

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 2,
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
                '${value.toInt()}h',
                style: TextStyle(fontSize: 10, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
              ),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: Colors.indigo,
            barWidth: 3,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.indigo.withValues(alpha: 0.1),
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityDistribution extends StatelessWidget {
  final Map<String, int> qualityDistribution;
  final int totalRecords;
  final bool isDark;

  const _QualityDistribution({
    required this.qualityDistribution,
    required this.totalRecords,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (label: '极好', count: qualityDistribution['极好']!, color: Colors.green),
      (label: '良好', count: qualityDistribution['良好']!, color: Colors.blue),
      (label: '一般', count: qualityDistribution['一般']!, color: Colors.amber),
      (label: '较差', count: qualityDistribution['较差']!, color: Colors.red),
    ];

    return Column(
      children: items.map((item) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? const Color(0xFFC2C6D6) : const Color(0xFF424754),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: totalRecords > 0 ? item.count / totalRecords : 0,
                    backgroundColor: isDark ? const Color(0xFF2A2D36) : const Color(0xFFECEDF7),
                    valueColor: AlwaysStoppedAnimation(item.color),
                    minHeight: 8,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 24,
                child: Text(
                  '${item.count}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8),
                  ),
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
