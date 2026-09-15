import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/core/health/mi_fitness_auth_service.dart';
import 'package:qnote_flutter/core/health/health_sync_service.dart';

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
  int _syncDaysRange = 3;

  @override
  void initState() {
    super.initState();
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
    }
  }

  Future<void> _handleSyncNow() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final syncService = ref.read(healthSyncServiceProvider);
      final res = await syncService.syncDays(daysBack: _syncDaysRange);

      if (!mounted) return;
      if (res.success) {
        Toast.success(
          context,
          '同步完成：已更新 ${res.syncedDays} 天健康数据，新增 ${res.newSportRecords} 条运动，沉淀 ${res.newTimelineCards} 张时间线卡片',
        );
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

  Future<void> _handleUnbind() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除小米健康绑定'),
        content: const Text('解除绑定后将停止自动同步健康数据，本地已保存的历史记录将继续保留。确认解绑吗？'),
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
      if (mounted) Toast.success(context, '已解除小米运动健康账号绑定');
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
              tooltip: '立即同步',
              onPressed: _isSyncing ? null : _handleSyncNow,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 账号授权卡片
                _buildAccountCard(context, isAuthed),
                const SizedBox(height: 16),

                // 数据沉淀与同步设置卡片
                _buildSyncOptionsCard(context, isAuthed),
                const SizedBox(height: 16),

                // 支持的数据维度介绍
                _buildSupportedMetricsCard(context),
              ],
            ),
    );
  }

  Widget _buildAccountCard(BuildContext context, bool isAuthed) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isAuthed
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.favorite_rounded,
                    color: isAuthed ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAuthed ? '已绑定小米账号' : '未连接小米运动健康',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isAuthed
                            ? '用户 ID: ${_credentials!.userId}'
                            : '扫码授权后可自动同步步数、睡眠与运动记录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isAuthed
                        ? Colors.green.withValues(alpha: 0.12)
                        : Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isAuthed ? Colors.green : Colors.orange,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isAuthed ? '已连接' : '未授权',
                        style: TextStyle(
                          color: isAuthed ? Colors.green.shade700 : Colors.orange.shade800,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            if (isAuthed) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '上次同步：${_lastSyncTime != null ? _formatDateTime(_lastSyncTime!) : '尚未同步'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.link_off, size: 18),
                        label: const Text('解除绑定'),
                        style: TextButton.styleFrom(
                          foregroundColor: colorScheme.error,
                        ),
                        onPressed: _isSyncing ? null : _handleUnbind,
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: _isSyncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.sync, size: 18),
                        label: Text(_isSyncing ? '同步中...' : '立即同步'),
                        onPressed: _isSyncing ? null : _handleSyncNow,
                      ),
                    ],
                  ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫码绑定小米账号'),
                  onPressed: _showQrLoginDialog,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSyncOptionsCard(BuildContext context, bool isAuthed) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4, bottom: 8),
              child: Text(
                '同步配置',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动沉淀至时间线'),
              subtitle: const Text('每次同步后，将单次运动和睡眠阶段自动生成对应的活动/作息卡片并防重归档'),
              value: _autoTimeline,
              onChanged: (val) async {
                setState(() => _autoTimeline = val);
                final syncService = ref.read(healthSyncServiceProvider);
                await syncService.setAutoCreateTimelineCards(val);
              },
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('同步历史跨度'),
              subtitle: Text('每次同步前推 $_syncDaysRange 天的数据'),
              trailing: DropdownButton<int>(
                value: _syncDaysRange,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('最近 1 天')),
                  DropdownMenuItem(value: 3, child: Text('最近 3 天')),
                  DropdownMenuItem(value: 7, child: Text('最近 7 天')),
                  DropdownMenuItem(value: 14, child: Text('最近 14 天')),
                  DropdownMenuItem(value: 30, child: Text('最近 30 天')),
                ],
                onChanged: isAuthed
                    ? (val) {
                        if (val != null) setState(() => _syncDaysRange = val);
                      }
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportedMetricsCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final metrics = [
      {'name': '日常步数', 'desc': '分钟切片采样与设备去重', 'icon': Icons.directions_walk},
      {'name': '睡眠分析', 'desc': '深睡/浅睡/REM分期与评分', 'icon': Icons.bedtime_outlined},
      {'name': '全天心率', 'desc': '连续心率曲线与静息心率', 'icon': Icons.favorite_outline},
      {'name': '血氧监测', 'desc': '全天血氧饱和度连续打点', 'icon': Icons.bloodtype_outlined},
      {'name': '压力指数', 'desc': '全天压力水平与极值', 'icon': Icons.mood_outlined},
      {'name': '单次运动', 'desc': '跑步、骑行、游泳与配速步频', 'icon': Icons.fitness_center},
    ];

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
            Text(
              '支持同步的指标类型',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 2.6,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: metrics.length,
              itemBuilder: (context, index) {
                final m = metrics[index];
                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        m['icon'] as IconData,
                        size: 22,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              m['name'] as String,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              m['desc'] as String,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 10,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$m-$d $h:$min';
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
  String _statusText = '正在生成小米账号授权二维码...';
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
        setState(() => _statusText = '授权成功！正在同步基础数据...');
        if (mounted) Toast.success(context, '小米运动健康授权绑定成功');
        // 后台触发一次同步
        final syncService = ref.read(healthSyncServiceProvider);
        syncService.syncDays(daysBack: 3);

        if (mounted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.of(context).pop();
          });
        }
      } else if (res.status == MiQrPollStatus.expired) {
        timer.cancel();
        setState(() => _statusText = '二维码已失效，请点击重试');
      } else if (res.status == MiQrPollStatus.failed) {
        // 继续等待或提示
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
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: CircularProgressIndicator(),
              )
            else if (_session != null) ...[
              Container(
                width: 220,
                height: 220,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
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
              const SizedBox(height: 16),
              Text(
                _statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
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
