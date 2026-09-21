import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';

import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';

class HealthStatsView extends ConsumerStatefulWidget {
  final DateTime startDate;
  final DateTime endDate;

  const HealthStatsView({
    super.key,
    required this.startDate,
    required this.endDate,
  });

  @override
  ConsumerState<HealthStatsView> createState() => _HealthStatsViewState();
}

class _HealthStatsViewState extends ConsumerState<HealthStatsView> {
  bool _isLoading = true;
  List<HealthDailyMetrics> _metricsList = [];
  List<HealthSportRecord> _sportRecords = [];
  bool _isAuthed = false;
  int _stepTarget = 8000; // 每日目标步数

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(covariant HealthStatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startDate != widget.startDate || oldWidget.endDate != widget.endDate) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final healthRepo = ref.read(healthMetricRepositoryProvider);
    final syncService = ref.read(healthSyncServiceProvider);

    final authed = await syncService.isAuthorized();
    final stepTarget = await syncService.getDailyStepTarget();
    final startStr = _formatDate(widget.startDate);
    final endStr = _formatDate(widget.endDate);

    final metrics = await healthRepo.getDailyMetricsRange(startStr, endStr);
    final sports = await healthRepo.getSportRecords(limit: 30);

    if (mounted) {
      setState(() {
        _isAuthed = authed;
        _stepTarget = stepTarget;
        _metricsList = metrics;
        _sportRecords = sports;
        _isLoading = false;
      });
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    if (!_isAuthed && _metricsList.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 32),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.favorite_rounded, size: 40, color: colorScheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              '开启运动健康监测',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              '授权连接后，步数、心率、睡眠分期、血氧、压力和运动记录将自动在此汇总分析，并支持小Q每日健康复盘。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('前往绑定小米账号'),
              onPressed: () => context.push('/settings/mi-fitness'),
            ),
          ],
        ),
      );
    }

    if (_metricsList.isEmpty && _sportRecords.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const EmptyStateWidget(
            icon: Icons.monitor_heart_outlined,
            message: '当前时间区间暂无运动健康数据',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.sync),
            label: const Text('立即从小米健康同步'),
            onPressed: () => context.push('/settings/mi-fitness'),
          ),
        ],
      );
    }

    // 计算区间聚合指标
    int totalSteps = 0;
    double totalCalories = 0;
    int totalActiveMinutes = 0;
    int totalSleepMins = 0;
    int sleepCount = 0;
    int hrSum = 0;
    int hrCount = 0;
    int spo2Sum = 0;
    int spo2Count = 0;
    int stressSum = 0;
    int stressCount = 0;

    for (final m in _metricsList) {
      totalSteps += m.steps;
      totalCalories += m.calories;
      totalActiveMinutes += m.activeMinutes;
      if (m.sleepDurationMinutes > 0) {
        totalSleepMins += m.sleepDurationMinutes;
        sleepCount++;
      }
      if (m.avgHeartRate != null && m.avgHeartRate! > 0) {
        hrSum += m.avgHeartRate!;
        hrCount++;
      }
      if (m.avgSpo2 != null && m.avgSpo2! > 0) {
        spo2Sum += m.avgSpo2!;
        spo2Count++;
      }
      if (m.avgStress != null && m.avgStress! > 0) {
        stressSum += m.avgStress!;
        stressCount++;
      }
    }

    final days = _metricsList.isNotEmpty ? _metricsList.length : 1;
    final avgDailySteps = totalSteps ~/ days;
    final avgSleepMin = sleepCount > 0 ? (totalSleepMins ~/ sleepCount) : 0;
    final avgHr = hrCount > 0 ? (hrSum ~/ hrCount) : null;
    final avgSpo2 = spo2Count > 0 ? (spo2Sum ~/ spo2Count) : null;
    final avgStress = stressCount > 0 ? (stressSum ~/ stressCount) : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 活力概览卡片
          _buildActivityOverviewCard(
            context,
            totalSteps: totalSteps,
            avgDailySteps: avgDailySteps,
            totalCalories: totalCalories,
            totalActiveMinutes: totalActiveMinutes,
          ),
          const SizedBox(height: 16),

          // 2. 步数柱状趋势图
          _buildStepsChartCard(context, isDark: isDark),
          const SizedBox(height: 16),

          // 3. 生理体征指标汇总 (心率/血氧/压力/睡眠)
          _buildVitalsGrid(
            context,
            avgSleepMin: avgSleepMin,
            avgHr: avgHr,
            avgSpo2: avgSpo2,
            avgStress: avgStress,
          ),
          const SizedBox(height: 16),

          // 4. 最近单次运动记录
          if (_sportRecords.isNotEmpty) ...[
            Text(
              '运动记录',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _sportRecords.length.clamp(0, 5),
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final r = _sportRecords[index];
                return _buildSportRecordTile(context, r);
              },
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildActivityOverviewCard(
    BuildContext context, {
    required int totalSteps,
    required int avgDailySteps,
    required double totalCalories,
    required int totalActiveMinutes,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '日常活动概览',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '共 ${_metricsList.length} 天',
                    style: TextStyle(
                      color: colorScheme.onPrimaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildMetricCol(
                    context,
                    label: '日均步数',
                    value: '$avgDailySteps',
                    unit: '步/天',
                    icon: Icons.directions_walk,
                    color: Colors.blue,
                  ),
                ),
                Expanded(
                  child: _buildMetricCol(
                    context,
                    label: '累计消耗',
                    value: totalCalories.toStringAsFixed(0),
                    unit: 'kcal',
                    icon: Icons.local_fire_department,
                    color: Colors.deepOrange,
                  ),
                ),
                Expanded(
                  child: _buildMetricCol(
                    context,
                    // 同小米健康页：这是步数采样分钟数，不是小米的中高强度活动时长
                    label: '计步分钟',
                    value: '${totalActiveMinutes ~/ 60}h${totalActiveMinutes % 60}m',
                    unit: '总计',
                    icon: Icons.timer,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCol(
    BuildContext context, {
    required String label,
    required String value,
    required String unit,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          unit,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.outline,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildStepsChartCard(BuildContext context, {required bool isDark}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < _metricsList.length; i++) {
      final m = _metricsList[i];
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: m.steps.toDouble(),
              color: m.steps >= _stepTarget ? Colors.green : colorScheme.primary,
              width: 12,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
            ),
          ],
        ),
      );
    }

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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '步数趋势',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  '目标 8,000 步',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: _metricsList.map((m) => m.steps.toDouble()).fold(10000.0, (a, b) => a > b ? a : b) * 1.1,
                  barGroups: barGroups,
                  titlesData: FlTitlesData(
                    show: true,
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (val, meta) {
                          if (val == 0) return const SizedBox.shrink();
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
                        getTitlesWidget: (val, meta) {
                          final idx = val.toInt();
                          if (idx >= 0 && idx < _metricsList.length) {
                            final date = _metricsList[idx].date;
                            final parts = date.split('-');
                            final label = parts.length == 3 ? '${parts[1]}/${parts[2]}' : date;
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVitalsGrid(
    BuildContext context, {
    required int avgSleepMin,
    required int? avgHr,
    required int? avgSpo2,
    required int? avgStress,
  }) {
    final sleepStr = avgSleepMin > 0 ? '${avgSleepMin ~/ 60}h ${avgSleepMin % 60}m' : '--';
    final hrStr = avgHr != null ? '$avgHr bpm' : '--';
    final spo2Str = avgSpo2 != null ? '$avgSpo2%' : '--';
    final stressStr = avgStress != null ? '$avgStress' : '--';

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        _buildVitalCard(
          context,
          title: '平均睡眠',
          value: sleepStr,
          subText: '深浅与REM分期监测',
          icon: Icons.bedtime_rounded,
          color: Colors.purple,
        ),
        _buildVitalCard(
          context,
          title: '平均心率',
          value: hrStr,
          subText: '全天连续心率采样',
          icon: Icons.favorite_rounded,
          color: Colors.red,
        ),
        _buildVitalCard(
          context,
          title: '平均血氧',
          value: spo2Str,
          subText: '正常范围 ≥ 95%',
          icon: Icons.bloodtype_rounded,
          color: Colors.teal,
        ),
        _buildVitalCard(
          context,
          title: '平均压力',
          value: stressStr,
          subText: (avgStress != null && avgStress < 50) ? '状态适度放松' : '注意规律休息',
          icon: Icons.mood_rounded,
          color: Colors.amber.shade800,
        ),
      ],
    );
  }

  Widget _buildVitalCard(
    BuildContext context, {
    required String title,
    required String value,
    required String subText,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              subText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 10,
                color: colorScheme.outline,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSportRecordTile(BuildContext context, HealthSportRecord r) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final distStr = r.distanceMeters > 0 ? '${(r.distanceMeters / 1000).toStringAsFixed(2)} km' : '';
    final durStr = '${r.durationSeconds ~/ 60} 分钟';
    final calStr = r.calories > 0 ? '${r.calories.toStringAsFixed(0)} kcal' : '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _getSportIcon(r.category),
              color: colorScheme.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    _formatDateTime(r.startTime),
                    durStr,
                    if (distStr.isNotEmpty) distStr,
                    if (calStr.isNotEmpty) calStr,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (r.avgHeartRate != null && r.avgHeartRate! > 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.favorite, size: 14, color: Colors.red),
                    const SizedBox(width: 2),
                    Text(
                      '${r.avgHeartRate}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                Text(
                  'bpm',
                  style: TextStyle(fontSize: 10, color: colorScheme.outline),
                ),
              ],
            ),
        ],
      ),
    );
  }

  IconData _getSportIcon(String category) {
    switch (category) {
      case 'running':
        return Icons.directions_run;
      case 'cycling':
        return Icons.directions_bike;
      case 'swimming':
        return Icons.pool;
      case 'walking':
        return Icons.directions_walk;
      default:
        return Icons.fitness_center;
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
