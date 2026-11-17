import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/health_colors.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/widgets/health/health_detail_parts.dart';

/// 睡眠分期 state 与展示样式的映射（云端：1 深睡 2/3 浅睡 4 清醒 5 REM）
///
/// 颜色统一取 [HealthColors]：过去这里写的是 Tailwind 500 档（#6366F1/#818CF8/
/// #38BDF8），与日结卡片、运动健康设置页三处各不相同，同一段睡眠在不同页面是
/// 三种紫蓝。现在三处共用同一支色阶。
const List<({int state, String label})> _sleepStates = [
  (state: 1, label: '深睡'),
  (state: 2, label: '浅睡'),
  (state: 3, label: '浅睡'),
  (state: 5, label: '快速眼动'),
  (state: 4, label: '清醒'),
];

Color _stateColor(int state, Brightness brightness) => switch (state) {
  1 => HealthColors.deepSleep(brightness),
  2 || 3 => HealthColors.lightSleep(brightness),
  5 => HealthColors.remSleep(brightness),
  _ => HealthColors.awake(brightness),
};

String _stateLabel(int state) =>
    _sleepStates.firstWhere((s) => s.state == state, orElse: () => (state: 0, label: '未知')).label;

String _hm(int minutes) => minutes <= 0 ? '--' : '${minutes ~/ 60}h${minutes % 60}m';

/// 睡眠详情页：入睡/醒来、时长构成、全天分期时间轴
///
/// 只用已入库的 `sleep_stages_json`（`{state, start, end, duration}`）与日汇总字段，
/// 不新增云端请求、不新增数据库列。睡眠效率/夜醒次数/睡眠期心率血氧需要建列且
/// 单位尚未在真实 payload 上核实，留作后续单独一步。
class SleepDetail extends StatelessWidget {
  const SleepDetail({super.key, required this.metrics});

  final HealthDailyMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stages =
        metrics
            .parseSleepStages()
            .where((s) => ((s['end'] as num?)?.toInt() ?? 0) > ((s['start'] as num?)?.toInt() ?? 0))
            .toList()
          ..sort((a, b) => ((a['start'] as num?)?.toInt() ?? 0).compareTo((b['start'] as num?)?.toInt() ?? 0));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        HealthDetailSection(
          title: '作息概览',
          subtitle: '入睡与醒来取当天最长的睡眠段',
          child: HealthStatRow(
            children: [
              HealthStatTile(label: '总时长', value: _hm(metrics.sleepDurationMinutes), hint: '含午睡等全部睡眠段'),
              HealthStatTile(label: '入睡', value: HealthDailyMetrics.sleepTimeToHHmm(metrics.sleepStartTime) ?? '--'),
              HealthStatTile(label: '醒来', value: HealthDailyMetrics.sleepTimeToHHmm(metrics.sleepEndTime) ?? '--'),
              HealthStatTile(
                label: '评分',
                value: metrics.sleepScore?.toString() ?? '--',
                valueColor: _scoreColor(metrics.sleepScore, theme.brightness),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HealthDetailSection(
          title: '睡眠分期时间轴',
          subtitle: stages.isEmpty ? '无分期数据，多为设备未整夜佩戴' : '按实际起止时间绘制',
          child: stages.isEmpty
              ? _emptyNote(context)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Timeline(stages: stages),
                    const SizedBox(height: 12),
                    HealthRatioLegend(
                      segments: [
                        for (final label in ['深睡', '浅睡', '快速眼动', '清醒'])
                          (
                            label: label,
                            text: _hm(_minutesByLabel(stages, label)),
                            color: _stateColor(_stateOfLabel(label), Theme.of(context).brightness),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        HealthDetailSection(
          title: '时长构成',
          child: HealthStatRow(
            children: [
              HealthStatTile(
                label: '深睡',
                value: _hm(metrics.deepSleepMinutes),
                hint: _percentOf(metrics.deepSleepMinutes, metrics.sleepDurationMinutes),
              ),
              HealthStatTile(
                label: '浅睡',
                value: _hm(metrics.lightSleepMinutes),
                hint: _percentOf(metrics.lightSleepMinutes, metrics.sleepDurationMinutes),
              ),
              HealthStatTile(
                label: '快速眼动',
                value: _hm(metrics.remSleepMinutes),
                hint: _percentOf(metrics.remSleepMinutes, metrics.sleepDurationMinutes),
              ),
              HealthStatTile(
                label: '清醒',
                value: _hm(metrics.awakeMinutes),
                hint: _percentOf(metrics.awakeMinutes, metrics.sleepDurationMinutes),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _emptyNote(BuildContext context) => Text(
    '暂无分期数据',
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );

  int _minutesByLabel(List<Map<String, dynamic>> stages, String label) {
    var total = 0;
    for (final s in stages) {
      if (_stateLabel((s['state'] as num?)?.toInt() ?? 0) == label) {
        total += (s['duration'] as num?)?.toInt() ?? 0;
      }
    }
    return total;
  }

  int _stateOfLabel(String label) => switch (label) {
    '深睡' => 1,
    '浅睡' => 2,
    '快速眼动' => 5,
    _ => 4,
  };

  String? _percentOf(int part, int total) => total <= 0 || part <= 0 ? null : '占比 ${(part / total * 100).round()}%';

  /// 睡眠评分分档：与运动健康设置页、睡眠评分徽标共用等级色阶。
  Color? _scoreColor(int? score, Brightness brightness) {
    if (score == null) return null;
    if (score >= 75) return HealthColors.levelGood(brightness);
    if (score >= 60) return HealthColors.levelWarn(brightness);
    return HealthColors.levelAlert(brightness);
  }
}

/// 分期时间轴：按真实起止时间等比铺一条分段色带，下方标出入睡/醒来时刻
class _Timeline extends StatelessWidget {
  const _Timeline({required this.stages});

  final List<Map<String, dynamic>> stages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final first = (stages.first['start'] as num).toInt();
    final last = stages.map((s) => (s['end'] as num).toInt()).reduce((a, b) => a > b ? a : b);
    final total = last - first;
    if (total <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 26,
            child: Row(
              children: [
                for (final s in stages)
                  Expanded(
                    flex: (((s['end'] as num).toInt() - (s['start'] as num).toInt()) / 1).round().clamp(1, 100000),
                    child: Container(color: _stateColor((s['state'] as num?)?.toInt() ?? 0, brightness)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_hhmm(first), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            Text(
              '共 ${_hm((total / 60).round())}',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(_hhmm(last), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ],
    );
  }

  String _hhmm(int epochSec) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
