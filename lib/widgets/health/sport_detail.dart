import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/health_colors.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';
import 'package:qnote_flutter/widgets/health/health_detail_parts.dart';

/// 单次运动详情页：概览、配速、心率五区间时长与训练负荷
///
/// 这些指标全部来自已入库的 `detail_json`（云端整条返回，之前没人解析），不额外请求。
/// 只外显**单位已核实**的字段：心率区间时长是秒（实测各段之和≈duration），
/// `recover_time`/`vitality`/`reserve_hr_zone` 单位未确认，先不外显，避免标错单位。
class SportDetail extends StatelessWidget {
  const SportDetail({super.key, required this.record});

  final HealthSportRecord record;

  /// 心率五区间：从「热身」到「极限」的强度梯度。
  ///
  /// 颜色走 [HealthColors] 的等级色阶（中性 → 蓝 → 绿 → 琥珀 → 红），
  /// 与心率详情、血氧/压力区间共用同一套语义，不再各写一份 Tailwind 500 档。
  static List<({String key, String label, Color color})> _hrZones(Brightness brightness) => [
    (key: 'hrm_warm_up_duration', label: '热身', color: HealthColors.awake(brightness)),
    (key: 'hrm_fat_burning_duration', label: '燃脂', color: HealthColors.levelInfo(brightness)),
    (key: 'hrm_aerobic_duration', label: '有氧', color: HealthColors.levelGood(brightness)),
    (key: 'hrm_anaerobic_duration', label: '无氧', color: HealthColors.levelWarn(brightness)),
    (key: 'hrm_extreme_duration', label: '极限', color: HealthColors.levelAlert(brightness)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final zones = _hrZones(theme.brightness);
    final detail = record.parseDetail();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        HealthDetailSection(
          title: '概览',
          subtitle: '${_hhmm(record.startTime)} - ${_hhmm(record.endTime)}',
          child: HealthStatRow(
            children: [
              HealthStatTile(label: '时长', value: _duration(record.durationSeconds)),
              HealthStatTile(
                label: '距离',
                value: record.distanceMeters > 0 ? (record.distanceMeters / 1000).toStringAsFixed(2) : '--',
                unit: record.distanceMeters > 0 ? 'km' : '',
              ),
              HealthStatTile(
                label: '消耗',
                value: record.calories > 0 ? record.calories.toStringAsFixed(0) : '--',
                unit: record.calories > 0 ? 'kcal' : '',
              ),
              HealthStatTile(
                label: '步数',
                value: (record.steps != null && record.steps! > 0) ? '${record.steps}' : '--',
              ),
            ],
          ),
        ),
        if (record.avgPace != null && record.avgPace! > 0) ...[
          const SizedBox(height: 12),
          HealthDetailSection(
            title: '配速与速度',
            child: HealthStatRow(
              children: [
                HealthStatTile(label: '平均配速', value: _pace(record.avgPace!)),
                HealthStatTile(
                  label: '最快配速',
                  value: (record.maxPace != null && record.maxPace! > 0) ? _pace(record.maxPace!) : '--',
                ),
                HealthStatTile(
                  label: '平均速度',
                  value: (record.avgSpeed != null && record.avgSpeed! > 0) ? record.avgSpeed!.toStringAsFixed(1) : '--',
                  unit: (record.avgSpeed != null && record.avgSpeed! > 0) ? 'km/h' : '',
                ),
                HealthStatTile(
                  label: '步频',
                  value: (record.avgCadence != null && record.avgCadence! > 0) ? '${record.avgCadence}' : '--',
                  unit: (record.avgCadence != null && record.avgCadence! > 0) ? 'spm' : '',
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        HealthDetailSection(
          title: '心率',
          child: HealthStatRow(
            children: [
              HealthStatTile(
                label: '平均',
                value: (record.avgHeartRate != null && record.avgHeartRate! > 0) ? '${record.avgHeartRate}' : '--',
                unit: 'bpm',
              ),
              HealthStatTile(
                label: '最高',
                value: (record.maxHeartRate != null && record.maxHeartRate! > 0) ? '${record.maxHeartRate}' : '--',
                unit: 'bpm',
                valueColor: HealthColors.levelAlert(theme.brightness),
              ),
              HealthStatTile(label: '最低', value: _intOf(detail, 'min_hrm')?.toString() ?? '--', unit: 'bpm'),
            ],
          ),
        ),
        if (_zoneSeconds(detail) > 0) ...[
          const SizedBox(height: 12),
          HealthDetailSection(
            title: '心率区间时长',
            subtitle: '合计 ${_duration(_zoneSeconds(detail).toInt())}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HealthRatioBar(
                  segments: [
                    for (final z in zones) (label: z.label, value: _numOf(detail, z.key) ?? 0, color: z.color),
                  ],
                ),
                const SizedBox(height: 10),
                HealthRatioLegend(
                  segments: [
                    for (final z in zones) (label: z.label, text: _minutes(_numOf(detail, z.key)), color: z.color),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_numOf(detail, 'train_load') != null) ...[
          const SizedBox(height: 12),
          HealthDetailSection(
            title: '训练负荷与效果',
            subtitle: '云端评估值，无量纲',
            child: HealthStatRow(
              children: [
                HealthStatTile(
                  label: '训练负荷',
                  value: _numOf(detail, 'train_load')!.toStringAsFixed(0),
                  hint: _intOfOrNull(detail, 'train_load_level') != null
                      ? '等级 ${_intOfOrNull(detail, 'train_load_level')}'
                      : null,
                ),
                HealthStatTile(
                  label: '有氧效果',
                  value:
                      _numOf(detail, 'train_effect')?.toStringAsFixed(1) ??
                      _numOf(detail, 'aerobic_train_effect')?.toStringAsFixed(1) ??
                      '--',
                ),
                HealthStatTile(
                  label: '无氧效果',
                  value: _numOf(detail, 'anaerobic_train_effect')?.toStringAsFixed(1) ?? '--',
                ),
              ],
            ),
          ),
        ],
        if (detail.isEmpty) ...[
          const SizedBox(height: 12),
          Center(
            child: Text(
              '无更多明细，重新同步可补齐',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  double? _numOf(Map<String, dynamic> detail, String key) {
    final v = detail[key];
    return v is num ? v.toDouble() : null;
  }

  int? _intOf(Map<String, dynamic> detail, String key) {
    final v = detail[key];
    return v is num && v > 0 ? v.toInt() : null;
  }

  /// 允许取 0 的整数字段（训练负荷等级 0 是有意义的取值）
  int? _intOfOrNull(Map<String, dynamic> detail, String key) {
    final v = detail[key];
    return v is num ? v.toInt() : null;
  }

  /// 心率五区间的 key 是固定的，求和不需要颜色；单独列出避免为取色而传 brightness。
  static const List<String> _hrZoneKeys = [
    'hrm_warm_up_duration',
    'hrm_fat_burning_duration',
    'hrm_aerobic_duration',
    'hrm_anaerobic_duration',
    'hrm_extreme_duration',
  ];

  double _zoneSeconds(Map<String, dynamic> detail) =>
      _hrZoneKeys.fold<double>(0, (a, key) => a + (_numOf(detail, key) ?? 0));

  String _minutes(double? seconds) {
    if (seconds == null || seconds <= 0) return '0分';
    return '${(seconds / 60).round()}分';
  }

  String _duration(int seconds) {
    if (seconds <= 0) return '--';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}h${m}m' : '$m分';
  }

  String _pace(double secPerKm) {
    final min = secPerKm ~/ 60;
    final sec = (secPerKm % 60).round().clamp(0, 59);
    return "$min'${sec.toString().padLeft(2, '0')}\"";
  }

  String _hhmm(DateTime dt) => '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
