import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/health_step_trend.dart';

/// 左侧步数刻度预留宽度，柱状图可用宽度按它扣减
const double _axisWidth = 40;

/// 无记录时间桶的占位淡柱高度比例
const double _emptyStubRatio = 0.02;

/// 步数趋势卡片：按 [buckets] 的粒度（按天 / 按月日均）出柱。
class StepsTrendChart extends StatelessWidget {
  final List<StepTrendBucket> buckets;
  final String caption;
  final int dailyTarget;

  const StepsTrendChart({
    super.key,
    required this.buckets,
    required this.caption,
    required this.dailyTarget,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Y 轴上限至少包住目标线，再抬到 2000 的整数倍，保证刻度落在整千
    final peak = buckets.fold<double>(dailyTarget.toDouble(), (a, b) => a > b.value ? a : b.value);
    final maxY = (peak * 1.15 / 2000).ceilToDouble() * 2000;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '步数趋势',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '目标 ${NumberFormat('#,###').format(dailyTarget)} 步',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
                ),
              ],
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                // 柱宽与刻度间隔都跟着可用宽度走：窄屏月视图变细，年视图自然收窄
                final plotWidth = math.max(1.0, constraints.maxWidth - _axisWidth);
                final barWidth = ((plotWidth / math.max(1, buckets.length)) * 0.62).clamp(3.0, 22.0);
                final labelInterval = stepAxisLabelInterval(
                  bucketCount: buckets.length,
                  plotWidth: plotWidth,
                  minLabelWidth:
                      buckets.isEmpty ? 30 : buckets.map((b) => b.labelWidth).reduce(math.max),
                );
                return SizedBox(
                  height: 180,
                  child: BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: maxY,
                      minY: 0,
                      barGroups: [
                        for (int i = 0; i < buckets.length; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                // 无记录只画一小段淡色底柱，避免空桶看起来比真实数据更高
                                toY: buckets[i].hasData
                                    ? buckets[i].value.clamp(0.0, maxY)
                                    : (maxY * _emptyStubRatio).clamp(0.0, maxY),
                                color: _rodColor(buckets[i], colorScheme),
                                width: barWidth,
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(buckets[i].hasData ? 4 : 2),
                                ),
                              ),
                            ],
                          ),
                      ],
                      barTouchData: BarTouchData(
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) =>
                              isDark ? const Color(0xFF2C2C2E) : colorScheme.surfaceContainerHigh,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            if (groupIndex < 0 || groupIndex >= buckets.length) {
                              return null;
                            }
                            final bucket = buckets[groupIndex];
                            final body = !bucket.hasData
                                ? '无记录'
                                : '${bucket.unit == StepTrendUnit.day ? '' : '日均 '}'
                                    '${NumberFormat('#,###').format(bucket.value.round())} 步';
                            return BarTooltipItem(
                              '${bucket.rangeLabel}\n$body',
                              TextStyle(
                                color: isDark ? Colors.white : colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            );
                          },
                        ),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: _axisWidth,
                            interval: maxY / 2,
                            getTitlesWidget: (val, meta) {
                              if (val == 0) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                '${(val / 1000).toStringAsFixed(0)}k',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (val, meta) {
                              final idx = val.toInt();
                              if (idx < 0 || idx >= buckets.length || idx % labelInterval != 0) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  buckets[idx].axisLabel,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: maxY / 2,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : Colors.black.withValues(alpha: 0.06),
                          strokeWidth: 1,
                          dashArray: const [4, 4],
                        ),
                      ),
                      // 汇总成日均之后，靠这条线才能判断达没达标
                      extraLinesData: ExtraLinesData(
                        horizontalLines: [
                          HorizontalLine(
                            y: dailyTarget.toDouble(),
                            color: Colors.green.withValues(alpha: 0.55),
                            strokeWidth: 1,
                            dashArray: const [5, 4],
                          ),
                        ],
                      ),
                      borderData: FlBorderData(show: false),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Color _rodColor(StepTrendBucket bucket, ColorScheme colorScheme) {
    if (!bucket.hasData) {
      return colorScheme.onSurface.withValues(alpha: 0.06);
    }
    return bucket.value >= dailyTarget ? Colors.green : colorScheme.primary;
  }
}
