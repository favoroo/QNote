import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/stats_card.dart';

class MoodStatsWidget extends StatelessWidget {
  final MoodStatistics stats;

  const MoodStatsWidget({super.key, required this.stats});

  String _severityLabel(double val) {
    if (val >= 2.5) return '轻微';
    if (val >= 1.5) return '中度';
    return '严重';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final symptomData = stats.symptomDistribution.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatsCard(
                title: '平均状态',
                value: stats.averageSeverity > 0 ? _severityLabel(stats.averageSeverity) : '无数据',
                icon: Icons.shield,
                iconColor: Colors.teal,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatsCard(
                title: '记录条数',
                value: '${stats.totalRecords}条',
                icon: Icons.local_activity,
                iconColor: Colors.pink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _MoodCard(
          isDark: isDark,
          title: '健康趋势 (评分越高越好)',
          child: SizedBox(
            height: 192,
            child: stats.dailyData.isNotEmpty
                ? _SeverityTrendChart(dailyData: stats.dailyData, isDark: isDark)
                : Center(child: Text('暂无数据', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)))),
          ),
        ),
        const SizedBox(height: 16),
        if (symptomData.isNotEmpty)
          _MoodCard(
            isDark: isDark,
            title: '症状分布',
            child: _SymptomDistribution(
              symptomData: symptomData,
              totalRecords: stats.totalRecords,
              isDark: isDark,
            ),
          ),
      ],
    );
  }
}

class _MoodCard extends StatelessWidget {
  final bool isDark;
  final String title;
  final Widget child;

  const _MoodCard({required this.isDark, required this.title, required this.child});

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
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isDark ? const Color(0xFFE2E2E9) : const Color(0xFF191B23),
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _SeverityTrendChart extends StatelessWidget {
  final List<({String date, double severity, String? symptom})> dailyData;
  final bool isDark;

  const _SeverityTrendChart({required this.dailyData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < dailyData.length; i++) {
      spots.add(FlSpot(i.toDouble(), dailyData[i].severity));
    }

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: 3,
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
              getTitlesWidget: (value, meta) {
                String label;
                if (value == 1) {
                  label = '严重';
                } else if (value == 2) {
                  label = '中度';
                } else if (value == 3) {
                  label = '轻微';
                } else {
                  label = '';
                }
                return Text(
                  label,
                  style: TextStyle(fontSize: 9, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
                );
              },
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
            color: Colors.teal,
            barWidth: 2,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.teal.withValues(alpha: 0.1),
            ),
          ),
        ],
      ),
    );
  }
}

class _SymptomDistribution extends StatelessWidget {
  final List<MapEntry<String, int>> symptomData;
  final int totalRecords;
  final bool isDark;

  const _SymptomDistribution({
    required this.symptomData,
    required this.totalRecords,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: symptomData.map((item) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    item.key,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFFE2E2E9) : const Color(0xFF424754),
                    ),
                  ),
                  Text(
                    '${item.value} 次',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: totalRecords > 0 ? item.value / totalRecords : 0,
                  backgroundColor: isDark ? const Color(0xFF2A2D36) : const Color(0xFFECEDF7),
                  valueColor: const AlwaysStoppedAnimation(Colors.teal),
                  minHeight: 6,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
