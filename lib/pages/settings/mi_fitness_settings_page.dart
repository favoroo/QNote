import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/core/health/mi_fitness_auth_service.dart';
import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';

class MiFitnessSettingsPage extends ConsumerStatefulWidget {
  const MiFitnessSettingsPage({super.key});

  @override
  ConsumerState<MiFitnessSettingsPage> createState() => _MiFitnessSettingsPageState();
}

class _MiFitnessSettingsPageState extends ConsumerState<MiFitnessSettingsPage> {
  bool _isLoading = true;
  bool _isSyncing = false;
  MiAuthCredentials? _credentials;
  DateTime? _lastSyncTime;
  bool _autoTimeline = true;

  // 日期浏览状态
  late DateTime _selectedDate;
  HealthDailyMetrics? _selectedMetrics;
  List<HealthSportRecord> _selectedSports = [];
  bool _isLoadingDate = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _loadState();
  }

  Future<void> _loadState() async {
    setState(() => _isLoading = true);
    final authService = ref.read(miFitnessAuthServiceProvider);
    final syncService = ref.read(healthSyncServiceProvider);

    final creds = await authService.loadCredentials();
    final lastSync = await syncService.getLastSyncTime();
    final autoTimeline = await syncService.getAutoCreateTimelineCards();

    if (mounted) {
      setState(() {
        _credentials = creds;
        _lastSyncTime = lastSync;
        _autoTimeline = autoTimeline;
        _isLoading = false;
      });
      await _loadDateData(_selectedDate);
    }
  }

  Future<void> _loadDateData(DateTime date) async {
    setState(() => _isLoadingDate = true);
    final healthRepo = ref.read(healthMetricRepositoryProvider);
    final dateStr = DateFormat('yyyy-MM-dd').format(date);

    final metrics = await healthRepo.getDailyMetrics(dateStr);
    final sports = await healthRepo.getSportRecordsByDate(dateStr);

    if (mounted) {
      setState(() {
        _selectedDate = DateTime(date.year, date.month, date.day);
        _selectedMetrics = metrics;
        _selectedSports = sports;
        _isLoadingDate = false;
      });
    }
  }

  Future<void> _handleSyncNow() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final syncService = ref.read(healthSyncServiceProvider);
      final res = await syncService.syncDays(daysBack: 7);

      if (!mounted) return;
      if (res.success) {
        Toast.success(context, '已同步最新健康数据');
        await _loadState();
      } else {
        Toast.error(context, res.errorMessage ?? '同步失败');
      }
    } catch (e) {
      if (mounted) Toast.error(context, '同步异常: $e');
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _handleSyncSelectedDate() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final syncService = ref.read(healthSyncServiceProvider);
      final res = await syncService.syncDate(_selectedDate);

      if (!mounted) return;
      if (res.success) {
        Toast.success(context, '已同步 ${_formatDateLabel(_selectedDate)} 数据');
        await _loadDateData(_selectedDate);
      } else {
        Toast.error(context, res.errorMessage ?? '同步失败');
      }
    } catch (e) {
      if (mounted) Toast.error(context, '同步异常: $e');
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _handleUnbind() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除小米健康绑定'),
        content: const Text('确定解除与当前小米账号的连接绑定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认解绑'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final authService = ref.read(miFitnessAuthServiceProvider);
      await authService.clearCredentials();
      if (mounted) Toast.success(context, '已解除绑定');
      await _loadState();
    }
  }

  void _showQrLoginDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _MiQrLoginDialog(),
    ).then((_) => _loadState());
  }

  void _changeDate(int offsetDays) {
    final newDate = _selectedDate.add(Duration(days: offsetDays));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (newDate.isAfter(today)) return;
    _loadDateData(newDate);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null) {
      _loadDateData(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAuthed = _credentials != null && _credentials!.ssecurity.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('小米运动健康'),
        actions: [
          if (isAuthed)
            IconButton(
              icon: _isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              tooltip: '同步数据',
              onPressed: _isSyncing ? null : _handleSyncNow,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                // 1. 账号连接状态卡片（极简）
                _buildAccountStatusCard(context, isAuthed),
                const SizedBox(height: 12),

                // 2. 日期切换导航栏
                _buildDateNavBar(context),
                const SizedBox(height: 12),

                // 3. 步数与活力主卡片
                _buildStepsCard(context),
                const SizedBox(height: 12),

                // 4. 生理体征指标（四宫格）
                _buildVitalsGrid(context),
                const SizedBox(height: 12),

                // 5. 单次运动记录列表
                if (_selectedSports.isNotEmpty) ...[
                  _buildSportRecordsSection(context),
                  const SizedBox(height: 12),
                ],

                // 6. 基础设置（自动沉淀开关）
                _buildPreferencesCard(context, isAuthed),
                const SizedBox(height: 16),
              ],
            ),
    );
  }

  Widget _buildAccountStatusCard(BuildContext context, bool isAuthed) {
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
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isAuthed ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.favorite_rounded,
                color: isAuthed ? colorScheme.primary : colorScheme.onSurfaceVariant,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isAuthed ? '小米账号: ${_credentials!.userId}' : '未连接小米账号',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isAuthed
                        ? (_lastSyncTime != null ? '上次同步 ${_formatDateTime(_lastSyncTime!)}' : '尚未同步')
                        : '扫码授权后可同步手环与运动数据',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (isAuthed)
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _isSyncing ? null : _handleSyncNow,
                child: Text(_isSyncing ? '同步中' : '立即同步'),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _showQrLoginDialog,
                child: const Text('扫码绑定'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateNavBar(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final now = DateTime.now();
    final isToday = _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 22),
            tooltip: '前一天',
            onPressed: () => _changeDate(-1),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _pickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      _formatDateLabel(_selectedDate),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!isToday) ...[
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => _loadDateData(DateTime(now.year, now.month, now.day)),
              child: const Text('今天', style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 22),
              tooltip: '后一天',
              onPressed: () => _changeDate(1),
            ),
          ] else
            const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildStepsCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m = _selectedMetrics;

    if (_isLoadingDate) {
      return const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final steps = m?.steps ?? 0;
    const targetSteps = 8000;
    final progress = (steps / targetSteps).clamp(0.0, 1.0);
    final distanceKm = m != null ? (m.distanceMeters / 1000).toStringAsFixed(2) : '0.00';
    final calStr = m != null ? m.calories.toStringAsFixed(0) : '0';
    final activeMin = m?.activeMinutes ?? 0;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_walk, size: 20, color: Colors.blue),
                    const SizedBox(width: 6),
                    Text(
                      '运动步数',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                if (m == null)
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('拉取此日数据', style: TextStyle(fontSize: 12)),
                    onPressed: _isSyncing ? null : _handleSyncSelectedDate,
                  )
                else
                  Text(
                    steps >= targetSteps ? '已达标' : '目标 8,000 步',
                    style: TextStyle(
                      fontSize: 12,
                      color: steps >= targetSteps ? Colors.green : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  NumberFormat('#,###').format(steps),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(width: 6),
                Text('步', style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.outline)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: steps >= targetSteps ? Colors.green : colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildSubMetric(
                    context,
                    label: '距离',
                    value: distanceKm,
                    unit: 'km',
                  ),
                ),
                Expanded(
                  child: _buildSubMetric(
                    context,
                    label: '消耗',
                    value: calStr,
                    unit: 'kcal',
                  ),
                ),
                Expanded(
                  child: _buildSubMetric(
                    context,
                    label: '活动时长',
                    value: '$activeMin',
                    unit: '分钟',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubMetric(
    BuildContext context, {
    required String label,
    required String value,
    required String unit,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 2),
            Text(
              unit,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.outline,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVitalsGrid(BuildContext context) {
    final m = _selectedMetrics;

    final sleepMins = m?.sleepDurationMinutes ?? 0;
    final sleepStr = sleepMins > 0 ? '${sleepMins ~/ 60}h ${sleepMins % 60}m' : '--';
    final sleepSub = (m?.deepSleepMinutes ?? 0) > 0 ? '深睡 ${m!.deepSleepMinutes}m' : '作息监测';

    final hrStr = m?.avgHeartRate != null && m!.avgHeartRate! > 0 ? '${m.avgHeartRate} bpm' : '--';
    final hrSub = m?.restingHeartRate != null ? '静息 ${m!.restingHeartRate}' : '连续心率';

    final spo2Str = m?.avgSpo2 != null && m!.avgSpo2! > 0 ? '${m.avgSpo2}%' : '--';
    final spo2Sub = (m?.minSpo2 ?? 0) > 0 ? '最低 ${m!.minSpo2}%' : '血氧饱和度';

    final stressStr = m?.avgStress != null && m!.avgStress! > 0 ? '${m.avgStress}' : '--';
    final stressSub = m?.maxStress != null ? '最高 ${m!.maxStress}' : '压力指数';

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 2.1,
      children: [
        _buildVitalTile(
          context,
          title: '睡眠',
          value: sleepStr,
          sub: sleepSub,
          icon: Icons.bedtime_rounded,
          color: Colors.purple,
        ),
        _buildVitalTile(
          context,
          title: '心率',
          value: hrStr,
          sub: hrSub,
          icon: Icons.favorite_rounded,
          color: Colors.red,
        ),
        _buildVitalTile(
          context,
          title: '血氧',
          value: spo2Str,
          sub: spo2Sub,
          icon: Icons.bloodtype_rounded,
          color: Colors.teal,
        ),
        _buildVitalTile(
          context,
          title: '压力',
          value: stressStr,
          sub: stressSub,
          icon: Icons.mood_rounded,
          color: Colors.orange,
        ),
      ],
    );
  }

  Widget _buildVitalTile(
    BuildContext context, {
    required String title,
    required String value,
    required String sub,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      sub,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.outline,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSportRecordsSection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '当天运动 (${_selectedSports.length})',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _selectedSports.length,
          separatorBuilder: (_, index) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final s = _selectedSports[index];
            final distStr = s.distanceMeters > 0 ? '${(s.distanceMeters / 1000).toStringAsFixed(2)} km' : '';
            final durStr = '${s.durationSeconds ~/ 60} 分钟';
            final calStr = s.calories > 0 ? '${s.calories.toStringAsFixed(0)} kcal' : '';

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.directions_run, color: colorScheme.primary, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          [durStr, if (distStr.isNotEmpty) distStr, if (calStr.isNotEmpty) calStr].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (s.avgHeartRate != null && s.avgHeartRate! > 0)
                    Text(
                      '${s.avgHeartRate} bpm',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildPreferencesCard(BuildContext context, bool isAuthed) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动生成时间线卡片'),
              subtitle: Text(
                '同步后将运动和睡眠自动归档为时间线记录',
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              value: _autoTimeline,
              onChanged: (val) async {
                setState(() => _autoTimeline = val);
                final syncService = ref.read(healthSyncServiceProvider);
                await syncService.setAutoCreateTimelineCards(val);
              },
            ),
            if (isAuthed) ...[
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.link_off, size: 20, color: colorScheme.error),
                title: Text(
                  '解除账号绑定',
                  style: TextStyle(color: colorScheme.error, fontSize: 14),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: _handleUnbind,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDateLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(DateTime(dt.year, dt.month, dt.day)).inDays;

    final dateStr = DateFormat('M月d日').format(dt);
    if (diff == 0) return '$dateStr 今天';
    if (diff == 1) return '$dateStr 昨天';
    if (diff == 2) return '$dateStr 前天';

    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final weekdayStr = weekdays[dt.weekday - 1];
    return '$dateStr $weekdayStr';
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('MM-dd HH:mm').format(dt);
  }
}

/// 扫码授权对话框
class _MiQrLoginDialog extends ConsumerStatefulWidget {
  const _MiQrLoginDialog();

  @override
  ConsumerState<_MiQrLoginDialog> createState() => _MiQrLoginDialogState();
}

class _MiQrLoginDialogState extends ConsumerState<_MiQrLoginDialog> {
  MiQrLoginSession? _session;
  bool _isLoading = true;
  String _statusText = '正在生成授权二维码...';
  Timer? _pollTimer;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _startQrFlow();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startQrFlow() async {
    final authService = ref.read(miFitnessAuthServiceProvider);
    try {
      final session = await authService.createQrSession();
      if (_isDisposed) return;

      setState(() {
        _session = session;
        _isLoading = false;
        _statusText = '请使用 小米运动健康 App 或 小米手机扫一扫 授权';
      });

      _startPolling(session.lp);
    } catch (e) {
      if (_isDisposed) return;
      setState(() {
        _isLoading = false;
        _statusText = '生成二维码失败: $e';
      });
    }
  }

  void _startPolling(String lp) {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_isDisposed) {
        timer.cancel();
        return;
      }

      final authService = ref.read(miFitnessAuthServiceProvider);
      final res = await authService.pollQrStatus(lp);

      if (_isDisposed) return;

      if (res.status == MiQrPollStatus.success) {
        timer.cancel();
        setState(() => _statusText = '授权成功！正在同步...');
        if (mounted) Toast.success(context, '授权绑定成功');
        final syncService = ref.read(healthSyncServiceProvider);
        syncService.syncDays(daysBack: 7);

        if (mounted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.of(context).pop();
          });
        }
      } else if (res.status == MiQrPollStatus.expired) {
        timer.cancel();
        setState(() => _statusText = '二维码已失效，请重试');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('绑定小米运动健康'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: CircularProgressIndicator(),
              )
            else if (_session != null) ...[
              Container(
                width: 200,
                height: 200,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _session!.qrCodeUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Center(
                      child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('在浏览器中登录'),
                onPressed: () async {
                  final uri = Uri.parse(_session!.loginUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(_statusText, style: TextStyle(color: colorScheme.error)),
              ),
              FilledButton(
                onPressed: () {
                  setState(() => _isLoading = true);
                  _startQrFlow();
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _pollTimer?.cancel();
            Navigator.of(context).pop();
          },
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
