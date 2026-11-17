import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/health_colors.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/widgets/health/health_day_line_chart.dart';
import 'package:qnote_flutter/widgets/health/health_detail_parts.dart';

/// 心率详情页：全天采样曲线 + 均值/静息/极值 + 采样点区间分布
///
/// 数据全部来自已入库的 `heart_rate_samples_json`，不额外请求云端。
/// 区间分布统计的是**采样点占比**而非时长占比——云端心率是离散采样，
/// 没有连续区间，写成「时长」会失真。
class HeartRateDetail extends StatelessWidget {
  const HeartRateDetail({super.key, required this.metrics});

  final HealthDailyMetrics metrics;

  /// 心率四区间：静息 → 日常 → 有氧 → 高强度，颜色取 [HealthColors] 等级色阶。
  static List<({String label, int min, int max, Color color})> _zones(Brightness brightness) => [
    (label: '< 60 静息区', min: 0, max: 59, color: HealthColors.levelInfo(brightness)),
    (label: '60-100 日常区', min: 60, max: 99, color: HealthColors.levelGood(brightness)),
    (label: '100-140 有氧区', min: 100, max: 139, color: HealthColors.levelWarn(brightness)),
    (label: '≥ 140 高强度区', min: 140, max: 100000, color: HealthColors.levelAlert(brightness)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final zones = _zones(theme.brightness);
    final samples = metrics.parseHeartRateSamples();
    final values = samples.map((s) => (s['v'] as num?)?.toInt()).whereType<int>().toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        HealthDetailSection(
          title: '全天心率曲线',
          subtitle: values.isEmpty ? '无心率采样，可能设备未佩戴或未同步' : '共 ${values.length} 个采样点，虚线为静息心率',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HealthDayLineChart(
                samples: samples,
                color: HealthColors.heartRate(theme.brightness),
                unit: '',
                emptyHint: '暂无心率采样',
                referenceValue: (metrics.restingHeartRate != null && metrics.restingHeartRate! > 0)
                    ? metrics.restingHeartRate!.toDouble()
                    : null,
                referenceLabel: '静息心率',
              ),
              if (metrics.restingHeartRate != null && metrics.restingHeartRate! > 0) ...[
                const SizedBox(height: 8),
                HealthChartReferenceNote(
                  label: '静息心率 ${metrics.restingHeartRate} bpm',
                  color: HealthColors.heartRate(theme.brightness),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        HealthDetailSection(
          title: '关键数值',
          child: HealthStatRow(
            children: [
              HealthStatTile(label: '平均', value: metrics.avgHeartRate?.toString() ?? '--', unit: 'bpm'),
              HealthStatTile(
                label: '静息',
                value: metrics.restingHeartRate?.toString() ?? '--',
                unit: 'bpm',
                valueColor: HealthColors.levelInfo(theme.brightness),
              ),
              HealthStatTile(label: '最低', value: metrics.minHeartRate?.toString() ?? '--', unit: 'bpm'),
              HealthStatTile(
                label: '最高',
                value: metrics.maxHeartRate?.toString() ?? '--',
                unit: 'bpm',
                valueColor: HealthColors.levelAlert(theme.brightness),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HealthDetailSection(
          title: '采样点区间分布',
          subtitle: '按采样点个数统计，非时长',
          child: values.isEmpty
              ? Text('暂无数据', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HealthRatioBar(
                      segments: [
                        for (final z in zones)
                          (
                            label: z.label,
                            value: values.where((v) => v >= z.min && v <= z.max).length.toDouble(),
                            color: z.color,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    HealthRatioLegend(
                      segments: [
                        for (final z in zones)
                          (
                            label: z.label,
                            text: '${values.where((v) => v >= z.min && v <= z.max).length}',
                            color: z.color,
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
