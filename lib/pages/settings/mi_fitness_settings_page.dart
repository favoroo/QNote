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
  final DateTime? initialDate;

  const MiFitnessSettingsPage({super.key, this.initialDate});

  @override
  ConsumerState<MiFitnessSettingsPage> createState() =>
      _MiFitnessSettingsPageState();
}

class _MiFitnessSettingsPageState extends ConsumerState<MiFitnessSettingsPage> {
  bool _isLoading = true;
  bool _isSyncing = false;
  MiAuthCredentials? _credentials;
  DateTime? _lastSyncTime;
  bool _autoSync = true;
  int _stepTarget = 8000; // 每日目标步数，默认 8000

  // 日期浏览状态
  late DateTime _selectedDate;
  HealthDailyMetrics? _selectedMetrics;
  List<HealthSportRecord> _selectedSports = [];
  bool _isLoadingDate = false;

  /// 同步进度通知器：(当前序号, 总天数, 状态文本)
  final _progressNotifier =
      ValueNotifier<({int current, int total, String message})>((
        current: 0,
        total: 0,
        message: '',
      ));

  @override
  void initState() {
    super.initState();
    final init = widget.initialDate ?? DateTime.now();
    _selectedDate = DateTime(init.year, init.month, init.day);
    _loadState();
  }

  @override
  void dispose() {
    _progressNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    setState(() => _isLoading = true);
    final authService = ref.read(miFitnessAuthServiceProvider);
    final syncService = ref.read(healthSyncServiceProvider);

    final creds = await authService.loadCredentials();
    final lastSync = await syncService.getLastSyncTime();
    final autoSync = await syncService.getAutoSync();
    final stepTarget = await syncService.getDailyStepTarget();

    if (mounted) {
      setState(() {
        _credentials = creds;
        _lastSyncTime = lastSync;
        _autoSync = autoSync;
        _stepTarget = stepTarget;
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

  Future<void> _handleSyncNow({int daysBack = 7}) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    _progressNotifier.value = (
      current: 0,
      total: daysBack + 1,
      message: '准备同步...',
    );

    // 批量同步（≥14天）时显示进度弹窗
    final showProgress = daysBack >= 14;
    // 提前获取 root navigator，避免 async 后 widget 已卸载时 context 失效
    final rootNav = showProgress
        ? Navigator.of(context, rootNavigator: true)
        : null;
    if (showProgress) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _SyncProgressDialog(notifier: _progressNotifier),
      );
    }

    try {
      final syncService = ref.read(healthSyncServiceProvider);
      final res = await syncService.syncDays(
        daysBack: daysBack,
        onProgress: (current, total, message) {
          _progressNotifier.value = (
            current: current,
            total: total,
            message: message,
          );
        },
      );

      // 先关闭进度弹窗（rootNav 在 async 前已捕获，安全可用）
      if (showProgress && rootNav != null) {
        rootNav.pop();
      }
      if (!mounted) return;
      if (res.success) {
        final label = daysBack >= 30 ? '最近$daysBack天' : '最新健康数据';
        Toast.success(context, '已同步$label（${res.syncedDays}天数据）');
        await _loadState();
      } else {
        Toast.error(context, res.errorMessage ?? '同步失败');
      }
    } catch (e) {
      if (showProgress && rootNav != null) {
        rootNav.pop();
      }
      if (mounted) Toast.error(context, '同步异常: $e');
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// 弹出底部抽屉让用户清晰选择同步 7天 / 30天 / 90天
  Future<void> _showSyncRangeSheet(BuildContext context) async {
    if (_isSyncing) return;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final days = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.sync_rounded, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '选择同步时间范围',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.today_rounded, color: Colors.blue, size: 20),
                ),
                title: const Text('同步最近 7 天'),
                subtitle: const Text('日常快速拉取，用时极短'),
                onTap: () => Navigator.of(ctx).pop(7),
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.calendar_month_rounded, color: Colors.teal, size: 20),
                ),
                title: const Text('同步最近 30 天'),
                subtitle: const Text('拉取近一个月完整数据与运动记录'),
                onTap: () => Navigator.of(ctx).pop(30),
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.purple.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.history_rounded, color: Colors.purple, size: 20),
                ),
                title: const Text('同步最近 90 天'),
                subtitle: const Text('拉取近一季度历史数据，首次同步推荐'),
                onTap: () => Navigator.of(ctx).pop(90),
              ),
            ],
          ),
        ),
      ),
    );

    if (days != null && mounted) {
      _handleSyncNow(daysBack: days);
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
        final lastSync = await syncService.getLastSyncTime();
        if (mounted) {
          setState(() => _lastSyncTime = lastSync);
        }
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
            _isSyncing
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.sync_rounded),
                    tooltip: '同步当前日期数据',
                    onPressed: _handleSyncSelectedDate,
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

                // 4. 深度作息睡眠卡片（含比例条、阶段明细、作息区间与评分徽标）
                _buildSleepCard(context),
                const SizedBox(height: 12),

                // 5. 心率健康深度指标卡片（静息心率、均值与极值范围、状态评估）
                _buildHeartRateCard(context),
                const SizedBox(height: 12),

                // 6. 血氧饱和度与全天压力双联状态卡片
                _buildSpo2AndStressRow(context),
                const SizedBox(height: 12),

                // 7. 单次运动记录列表
                if (_selectedSports.isNotEmpty) ...[
                  _buildSportRecordsSection(context),
                  const SizedBox(height: 12),
                ],

                // 8. 基础设置（自动沉淀开关）
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
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isAuthed ? '小米账号: ${_credentials!.userId}' : '未连接小米账号',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isAuthed) ...[
                    const SizedBox(height: 2),
                    Text(
                      _lastSyncTime != null
                          ? '上次同步 ${_formatDateTime(_lastSyncTime!)}'
                          : '尚未同步',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isAuthed)
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _isSyncing ? null : () => _showSyncRangeSheet(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_isSyncing ? '同步中' : '同步'),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
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
    final isToday =
        _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
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
              onPressed: () =>
                  _loadDateData(DateTime(now.year, now.month, now.day)),
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
    final targetSteps = _stepTarget;
    final progress = (steps / targetSteps).clamp(0.0, 1.0);
    final distanceKm = m != null
        ? (m.distanceMeters / 1000).toStringAsFixed(2)
        : '0.00';
    final calStr = m != null ? m.calories.toStringAsFixed(0) : '0';
    final activeMin = m?.activeMinutes ?? 0;
    final standing = m?.standingCount ?? 0;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
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
                    const Icon(
                      Icons.directions_walk,
                      size: 20,
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '运动步数',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (m == null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('拉取此日数据', style: TextStyle(fontSize: 12)),
                    onPressed: _isSyncing ? null : _handleSyncSelectedDate,
                  )
                else
                  Text(
                    steps >= targetSteps
                        ? '已达标'
                        : '目标 ${NumberFormat('#,###').format(targetSteps)} 步',
                    style: TextStyle(
                      fontSize: 12,
                      color: steps >= targetSteps
                          ? Colors.green
                          : colorScheme.onSurfaceVariant,
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
                Text(
                  '步',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: steps >= targetSteps
                    ? Colors.green
                    : colorScheme.primary,
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
                Expanded(
                  child: _buildSubMetric(
                    context,
                    label: '站立',
                    value: '$standing',
                    unit: '次',
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
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
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

  /// 睡眠监测深度分析卡片
  Widget _buildSleepCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m = _selectedMetrics;

    const sleepPurple = Color(0xFF8B5CF6);
    final sleepMins = m?.sleepDurationMinutes ?? 0;
    final deepMins = m?.deepSleepMinutes ?? 0;
    final lightMins = m?.lightSleepMinutes ?? 0;
    final remMins = m?.remSleepMinutes ?? 0;
    final awakeMins = m?.awakeMinutes ?? 0;
    final sleepScore = m?.sleepScore;

    final startStr = _formatSleepTime(m?.sleepStartTime);
    final endStr = _formatSleepTime(m?.sleepEndTime);
    final hasTimeRange = startStr != null && endStr != null;

    final totalStages = deepMins + lightMins + remMins + awakeMins;
    final calcTotal = totalStages > 0 ? totalStages : (sleepMins > 0 ? sleepMins : 1);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：图标 + 标题 + 睡眠时长 + 评分
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: sleepPurple.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.nightlight_round,
                    size: 18,
                    color: sleepPurple,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '作息睡眠',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (sleepMins > 0) ...[
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '${sleepMins ~/ 60}小时${sleepMins % 60}分',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: sleepPurple,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (sleepScore != null && sleepScore > 0) ...[
                          const SizedBox(width: 6),
                          _buildSleepScoreBadge(sleepScore),
                        ],
                      ],
                    ),
                  ),
                ] else
                  Text(
                    '未检测到',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
              ],
            ),

            if (sleepMins > 0) ...[
              const SizedBox(height: 14),
              // 入睡与醒来作息起止时间（对齐比例条两端）
              if (hasTimeRange) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bedtime_outlined,
                          size: 13,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '入睡 $startStr',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.wb_sunny_outlined,
                          size: 13,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '醒来 $endStr',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              // 睡眠分期比例条
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      if (deepMins > 0)
                        Expanded(
                          flex: (deepMins * 100 ~/ calcTotal).clamp(1, 100),
                          child: Container(
                            color: const Color(0xFF6366F1), // 深睡
                          ),
                        ),
                      if (lightMins > 0)
                        Expanded(
                          flex: (lightMins * 100 ~/ calcTotal).clamp(1, 100),
                          child: Container(
                            color: const Color(0xFFA855F7), // 浅睡
                          ),
                        ),
                      if (remMins > 0)
                        Expanded(
                          flex: (remMins * 100 ~/ calcTotal).clamp(1, 100),
                          child: Container(
                            color: const Color(0xFF38BDF8), // REM
                          ),
                        ),
                      if (awakeMins > 0)
                        Expanded(
                          flex: (awakeMins * 100 ~/ calcTotal).clamp(1, 100),
                          child: Container(
                            color: const Color(0xFFCBD5E1), // 清醒
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),
              // 4分期指标网格
              Row(
                children: [
                  Expanded(
                    child: _buildSleepStageItem(
                      context,
                      label: '深睡',
                      minutes: deepMins,
                      pct: calcTotal > 0 ? (deepMins * 100 ~/ calcTotal) : 0,
                      color: const Color(0xFF6366F1),
                    ),
                  ),
                  Expanded(
                    child: _buildSleepStageItem(
                      context,
                      label: '浅睡',
                      minutes: lightMins,
                      pct: calcTotal > 0 ? (lightMins * 100 ~/ calcTotal) : 0,
                      color: const Color(0xFFA855F7),
                    ),
                  ),
                  Expanded(
                    child: _buildSleepStageItem(
                      context,
                      label: '快速眼动',
                      minutes: remMins,
                      pct: calcTotal > 0 ? (remMins * 100 ~/ calcTotal) : 0,
                      color: const Color(0xFF38BDF8),
                    ),
                  ),
                  Expanded(
                    child: _buildSleepStageItem(
                      context,
                      label: '清醒',
                      minutes: awakeMins,
                      pct: calcTotal > 0 ? (awakeMins * 100 ~/ calcTotal) : 0,
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '当天暂无睡眠监测数据，佩戴手环/手表入睡后将自动同步睡眠分期与分析',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSleepScoreBadge(int score) {
    Color badgeColor;
    String scoreText;
    if (score >= 90) {
      badgeColor = const Color(0xFF10B981);
      scoreText = '$score分 极佳';
    } else if (score >= 75) {
      badgeColor = const Color(0xFF8B5CF6);
      scoreText = '$score分 良好';
    } else if (score >= 60) {
      badgeColor = const Color(0xFFF59E0B);
      scoreText = '$score分 一般';
    } else {
      badgeColor = const Color(0xFFEF4444);
      scoreText = '$score分 偏低';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: badgeColor.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Text(
        scoreText,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: badgeColor,
        ),
      ),
    );
  }

  Widget _buildSleepStageItem(
    BuildContext context, {
    required String label,
    required int minutes,
    required int pct,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final hours = minutes ~/ 60;
    final remainMins = minutes % 60;
    final timeStr = hours > 0 ? '${hours}h ${remainMins}m' : '${remainMins}m';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          timeStr,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        Text(
          '$pct%',
          style: TextStyle(
            fontSize: 10,
            color: colorScheme.outline,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// 心率健康卡片
  Widget _buildHeartRateCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m = _selectedMetrics;

    const hrColor = Color(0xFFEF4444);
    final avgHr = m?.avgHeartRate;
    final restingHr = m?.restingHeartRate;
    final minHr = m?.minHeartRate;
    final maxHr = m?.maxHeartRate;

    final hasHrData = (avgHr != null && avgHr > 0) ||
        (restingHr != null && restingHr > 0);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: hrColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    size: 18,
                    color: hrColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '心率健康',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (hasHrData)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        avgHr != null ? '$avgHr' : '--',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: hrColor,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        'bpm 平均',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.outline,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    '暂无数据',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 14),

            // 指标三列
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    context,
                    label: '静息心率',
                    value: restingHr != null && restingHr > 0
                        ? '$restingHr'
                        : '--',
                    unit: 'bpm',
                    tag: restingHr != null && restingHr > 0 && restingHr <= 75
                        ? '优质'
                        : null,
                    tagColor: Colors.green,
                  ),
                ),
                Expanded(
                  child: _buildMetricTile(
                    context,
                    label: '全天最低',
                    value: minHr != null && minHr > 0 ? '$minHr' : '--',
                    unit: 'bpm',
                  ),
                ),
                Expanded(
                  child: _buildMetricTile(
                    context,
                    label: '全天最高',
                    value: maxHr != null && maxHr > 0 ? '$maxHr' : '--',
                    unit: 'bpm',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 血氧与压力双联卡片
  Widget _buildSpo2AndStressRow(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m = _selectedMetrics;

    const spo2Color = Color(0xFF0D9488);
    const stressColor = Color(0xFFF97316);

    final avgSpo2 = m?.avgSpo2;
    final minSpo2 = m?.minSpo2;
    final hasSpo2 = avgSpo2 != null && avgSpo2 > 0;

    final avgStress = m?.avgStress;
    final maxStress = m?.maxStress;
    final hasStress = avgStress != null && avgStress > 0;

    return Row(
      children: [
        // 血氧卡片
        Expanded(
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.large),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.water_drop_rounded, size: 16, color: spo2Color),
                          const SizedBox(width: 4),
                          Text(
                            '血氧饱和度',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      if (hasSpo2)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: (avgSpo2 >= 95 ? Colors.green : Colors.orange)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            avgSpo2 >= 95 ? '正常' : '偏低',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: avgSpo2 >= 95 ? Colors.green : Colors.orange,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        hasSpo2 ? '$avgSpo2' : '--',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: hasSpo2 ? spo2Color : null,
                        ),
                      ),
                      if (hasSpo2) ...[
                        const SizedBox(width: 2),
                        Text(
                          '%',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    minSpo2 != null && minSpo2 > 0 ? '最低 $minSpo2%' : '连续监测',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 压力卡片
        Expanded(
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.large),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.mood_rounded, size: 16, color: stressColor),
                          const SizedBox(width: 4),
                          Text(
                            '全天压力',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      if (hasStress)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: _getStressColor(avgStress).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getStressLabel(avgStress),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: _getStressColor(avgStress),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        hasStress ? '$avgStress' : '--',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: hasStress ? stressColor : null,
                        ),
                      ),
                      if (hasStress) ...[
                        const SizedBox(width: 2),
                        Text(
                          '指数',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.outline,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    maxStress != null && maxStress > 0 ? '最高 $maxStress' : '身心负荷',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricTile(
    BuildContext context, {
    required String label,
    required String value,
    required String unit,
    String? tag,
    Color? tagColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
            if (tag != null) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: (tagColor ?? Colors.green).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: tagColor ?? Colors.green,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (value != '--') ...[
              const SizedBox(width: 2),
              Text(
                unit,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.outline,
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  String? _formatSleepTime(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) return null;
    if (timeStr.contains('T')) {
      final dt = DateTime.tryParse(timeStr);
      if (dt != null) {
        return DateFormat('HH:mm').format(dt.toLocal());
      }
    }
    return timeStr;
  }

  Color _getStressColor(int stress) {
    if (stress < 30) return const Color(0xFF10B981); // 轻松 绿
    if (stress < 60) return const Color(0xFF3B82F6); // 正常 蓝
    if (stress < 80) return const Color(0xFFF59E0B); // 中等 橙
    return const Color(0xFFEF4444); // 偏高 红
  }

  String _getStressLabel(int stress) {
    if (stress < 30) return '轻松';
    if (stress < 60) return '正常';
    if (stress < 80) return '中等';
    return '偏高';
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
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _selectedSports.length,
          separatorBuilder: (_, index) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final s = _selectedSports[index];
            final distStr = s.distanceMeters > 0
                ? '${(s.distanceMeters / 1000).toStringAsFixed(2)} km'
                : '';
            final durStr = '${s.durationSeconds ~/ 60} 分钟';
            final calStr = s.calories > 0
                ? '${s.calories.toStringAsFixed(0)} kcal'
                : '';

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.35,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.directions_run,
                      color: colorScheme.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          [
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
                  if (s.avgHeartRate != null && s.avgHeartRate! > 0)
                    Text(
                      '${s.avgHeartRate} bpm',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// 弹窗编辑每日目标步数，提供快捷预设与自定义输入
  Future<void> _showStepTargetEditor() async {
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _StepTargetSheet(initial: _stepTarget),
    );

    if (result != null && result != _stepTarget && mounted) {
      final syncService = ref.read(healthSyncServiceProvider);
      await syncService.setDailyStepTarget(result);
      setState(() => _stepTarget = result);
      if (mounted) {
        Toast.success(context, '每日目标步数已设为 ${NumberFormat('#,###').format(result)} 步');
      }
    }
  }

  Widget _buildPreferencesCard(BuildContext context, bool isAuthed) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动同步'),
              value: _autoSync,
              onChanged: (val) async {
                setState(() => _autoSync = val);
                final syncService = ref.read(healthSyncServiceProvider);
                await syncService.setAutoSync(val);
              },
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.flag_rounded,
                size: 20,
                color: Colors.blue,
              ),
              title: const Text('每日目标步数'),
              subtitle: Text(
                '${NumberFormat('#,###').format(_stepTarget)} 步',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: _showStepTargetEditor,
            ),
            if (isAuthed) ...[
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.link_off,
                  size: 20,
                  color: colorScheme.error,
                ),
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
                      child: Icon(
                        Icons.broken_image,
                        size: 40,
                        color: Colors.grey,
                      ),
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
                child: Text(
                  _statusText,
                  style: TextStyle(color: colorScheme.error),
                ),
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

/// 批量同步进度弹窗
class _SyncProgressDialog extends StatelessWidget {
  final ValueNotifier<({int current, int total, String message})> notifier;

  const _SyncProgressDialog({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.sync_rounded, size: 20),
          SizedBox(width: 8),
          Text('批量同步中', style: TextStyle(fontSize: 16)),
        ],
      ),
      content:
          ValueListenableBuilder<({int current, int total, String message})>(
            valueListenable: notifier,
            builder: (ctx, state, _) {
              final progress = state.total > 0
                  ? (state.current / state.total).clamp(0.0, 1.0)
                  : 0.0;
              final percent = (progress * 100).toInt();

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    state.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$percent%',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }
}

/// 每日目标步数选择底部弹窗
class _StepTargetSheet extends StatefulWidget {
  final int initial;

  const _StepTargetSheet({required this.initial});

  @override
  State<_StepTargetSheet> createState() => _StepTargetSheetState();
}

class _StepTargetSheetState extends State<_StepTargetSheet> {
  late final TextEditingController _controller;
  int? _selectedPreset;

  static const _presets = [5000, 6000, 7000, 8000, 9000, 10000, 12000];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial.toString());
    _selectedPreset = _presets.contains(widget.initial) ? widget.initial : null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.flag_rounded, size: 20),
                const SizedBox(width: 8),
                Text(
                  '每日目标步数',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets.map((v) {
                final isSelected = v == _selectedPreset;
                return ChoiceChip(
                  label: Text('${NumberFormat('#,###').format(v)} 步'),
                  selected: isSelected,
                  onSelected: (_) {
                    setState(() {
                      _selectedPreset = v;
                      _controller.text = v.toString();
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '自定义步数',
                suffixText: '步',
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                final parsed = int.tryParse(val);
                if (parsed != null && _presets.contains(parsed)) {
                  setState(() => _selectedPreset = parsed);
                } else {
                  setState(() => _selectedPreset = null);
                }
              },
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(_controller.text.trim());
                  if (parsed != null && parsed > 0) {
                    Navigator.of(context).pop(parsed);
                  }
                },
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
