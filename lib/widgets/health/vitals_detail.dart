import 'package:flutter/material.dart';

import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/widgets/health/health_day_line_chart.dart';
import 'package:qnote_flutter/widgets/health/health_detail_parts.dart';

/// 血氧与压力详情页：两条日内曲线 + 各自分级分布
///
/// 数据来自已入库的 `spo2_samples_json` / `stress_samples_json`，不额外请求云端。
/// 分级分布同样按**采样点个数**统计：云端给的是离散测量值，不是连续时长。
class VitalsDetail extends StatelessWidget {
  const VitalsDetail({super.key, required this.metrics});

  final HealthDailyMetrics metrics;

  static const List<({String label, int min, int max, Color color})> _spo2Zones = [
    (label: '< 90 偏低', min: 0, max: 89, color: Color(0xFFEF4444)),
    (label: '90-94 正常偏低', min: 90, max: 94, color: Color(0xFFF59E0B)),
    (label: '≥ 95 正常', min: 95, max: 1000, color: Color(0xFF10B981)),
  ];

  static const List<({String label, int min, int max, Color color})> _stressZones = [
    (label: '0-29 放松', min: 0, max: 29, color: Color(0xFF10B981)),
    (label: '30-59 正常', min: 30, max: 59, color: Color(0xFF0EA5E9)),
    (label: '60-79 中等', min: 60, max: 79, color: Color(0xFFF59E0B)),
    (label: '80-100 偏高', min: 80, max: 1000, color: Color(0xFFEF4444)),
  ];

  @override
  Widget build(BuildContext context) {
    final spo2Samples = metrics.parseSpo2Samples();
    final stressSamples = metrics.parseStressSamples();
    final spo2Values = spo2Samples.map((s) => (s['v'] as num?)?.toInt()).whereType<int>().toList();
    final stressValues = stressSamples.map((s) => (s['v'] as num?)?.toInt()).whereType<int>().toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        HealthDetailSection(
          title: '血氧饱和度',
          subtitle: spo2Values.isEmpty ? '这一天没有血氧测量，多为设备未开启连续监测' : '共 ${spo2Values.length} 次测量',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              HealthStatRow(
                children: [
                  HealthStatTile(
                    label: '平均',
                    value: metrics.avgSpo2?.toString() ?? '--',
                    unit: '%',
                  ),
                  HealthStatTile(
                    label: '最低',
                    value: metrics.minSpo2?.toString() ?? '--',
                    unit: '%',
                    valueColor: (metrics.minSpo2 != null && metrics.minSpo2! < 90) ? Colors.redAccent : null,
                    hint: (metrics.minSpo2 != null && metrics.minSpo2! < 90) ? '低于 90% 值得关注' : null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              HealthDayLineChart(
                samples: spo2Samples,
                color: Colors.teal,
                unit: '%',
                emptyHint: '暂无血氧测量',
              ),
              const SizedBox(height: 12),
              _zoneDistribution(context, spo2Values, _spo2Zones),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HealthDetailSection(
          title: '全天压力',
          subtitle: stressValues.isEmpty ? '这一天没有压力采样' : '共 ${stressValues.length} 个采样点',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              HealthStatRow(
                children: [
                  HealthStatTile(
                    label: '平均',
                    value: metrics.avgStress?.toString() ?? '--',
                    unit: '指数',
                  ),
                  HealthStatTile(
                    label: '最高',
                    value: metrics.maxStress?.toString() ?? '--',
                    unit: '指数',
                    valueColor: (metrics.maxStress != null && metrics.maxStress! >= 80) ? Colors.orange : null,
                  ),
                  HealthStatTile(
                    label: '放松时段',
                    value: '${stressValues.where((v) => v <= 29).length}',
                    unit: '点',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              HealthDayLineChart(
                samples: stressSamples,
                color: Colors.indigo,
                unit: '',
                emptyHint: '暂无压力采样',
              ),
              const SizedBox(height: 12),
              _zoneDistribution(context, stressValues, _stressZones),
            ],
          ),
        ),
      ],
    );
  }

  Widget _zoneDistribution(
    BuildContext context,
    List<int> values,
    List<({String label, int min, int max, Color color})> zones,
  ) {
    if (values.isEmpty) {
      return Text(
        '暂无数据',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    int countOf(({String label, int min, int max, Color color}) z) =>
        values.where((v) => v >= z.min && v <= z.max).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HealthRatioBar(
          segments: [for (final z in zones) (label: z.label, value: countOf(z).toDouble(), color: z.color)],
        ),
        const SizedBox(height: 10),
        HealthRatioLegend(
          segments: [for (final z in zones) (label: z.label, text: '${countOf(z)}', color: z.color)],
        ),
      ],
    );
  }
}
