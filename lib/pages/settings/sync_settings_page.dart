import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/core/network/webdav_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/sync_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';

/// 同步设置页面
///
/// 遵循轻量化与新用户友好原则：
/// 1. WebDAV 服务器配置置顶，并内置“测试连接”功能；
/// 2. 简化日常同步选项，自动同步集成后台与启动时机制；
/// 3. 提供醒目的“立即同步”核心主操作；
/// 4. 将低频运维与高危“从远程恢复”收纳进“高级与数据恢复”折叠面板中。
class SyncSettingsPage extends ConsumerStatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  ConsumerState<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends ConsumerState<SyncSettingsPage> {
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _remotePathController = TextEditingController();

  bool _obscurePassword = true;
  bool _webdavEnabled = false;
  bool _syncOnLaunch = true;
  bool _syncImages = true;
  int _syncInterval = 15;
  bool _testing = false;
  bool _showAdvancedPath = false;
  StreamSubscription<SyncStatus>? _statusSubscription;

  // 记录初始配置值，用于判断是否有未保存的更改
  String _initialServerUrl = '';
  String _initialUsername = '';
  String _initialPassword = '';
  String _initialRemotePath = '';
  bool _initialWebdavEnabled = false;
  bool _initialSyncOnLaunch = true;
  bool _initialSyncImages = true;
  int _initialSyncInterval = 15;

  static const _syncIntervalOptions = <MapEntry<String, int>>[
    MapEntry('5 分钟', 5),
    MapEntry('15 分钟', 15),
    MapEntry('30 分钟', 30),
    MapEntry('1 小时', 60),
    MapEntry('6 小时', 360),
  ];

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _statusSubscription = SyncScheduler.instance.statusStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _remotePathController.dispose();
    super.dispose();
  }

  void _updateInitialValues() {
    _initialServerUrl = _serverUrlController.text.trim();
    _initialUsername = _usernameController.text.trim();
    _initialPassword = _passwordController.text;
    _initialRemotePath = _remotePathController.text.trim().isEmpty
        ? 'QNote'
        : _remotePathController.text.trim();
    _initialWebdavEnabled = _webdavEnabled;
    _initialSyncOnLaunch = _syncOnLaunch;
    _initialSyncImages = _syncImages;
    _initialSyncInterval = _syncInterval;
  }

  bool _hasUnsavedChanges() {
    return _serverUrlController.text.trim() != _initialServerUrl ||
        _usernameController.text.trim() != _initialUsername ||
        _passwordController.text != _initialPassword ||
        _remotePathController.text.trim() != _initialRemotePath ||
        _webdavEnabled != _initialWebdavEnabled ||
        _syncOnLaunch != _initialSyncOnLaunch ||
        _syncImages != _initialSyncImages ||
        _syncInterval != _initialSyncInterval;
  }

  Future<bool> _showUnsavedChangesDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的更改'),
        content: const Text('您有未保存的同步设置更改，是否保存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('放弃更改', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == 'save') {
      await _saveConfig();
      return true;
    } else if (result == 'discard') {
      return true;
    }
    return false;
  }

  Future<void> _loadConfig() async {
    try {
      final config = await ref.read(webdavConfigProvider.future);
      final syncOnLaunchStr = await ConfigRepository.instance.getAppConfig('webdav_sync_on_launch');
      final syncOnLaunch = syncOnLaunchStr == null ? true : syncOnLaunchStr == 'true';
      final syncImagesStr = await ConfigRepository.instance.getAppConfig('webdav_sync_images');
      final syncImages = syncImagesStr == null ? true : syncImagesStr == 'true';

      if (config != null) {
        _serverUrlController.text = config.serverUrl;
        _usernameController.text = config.username;
        _passwordController.text = config.password;
        _remotePathController.text = config.remotePath;
        setState(() {
          _webdavEnabled = config.autoSync;
          _syncOnLaunch = syncOnLaunch;
          _syncImages = syncImages;
          _syncInterval = config.syncInterval <= 0 ? 15 : config.syncInterval;
        });
      } else {
        _remotePathController.text = 'QNote';
        setState(() {
          _webdavEnabled = false;
          _syncOnLaunch = syncOnLaunch;
          _syncImages = syncImages;
          _syncInterval = 15;
        });
      }
      _updateInitialValues();
    } catch (_) {
      _remotePathController.text = 'QNote';
      _updateInitialValues();
    }
  }

  void _showNotification(String message, {bool isError = false, bool isSuccess = false}) {
    if (!mounted) return;
    if (isError) {
      Toast.error(context, message);
    } else if (isSuccess) {
      Toast.success(context, message);
    } else {
      Toast.info(context, message);
    }
  }

  Future<void> _saveConfig({bool silent = false}) async {
    final existing = await ref.read(webdavConfigProvider.future).catchError((_) => null);

    final config = WebdavConfig(
      id: 'default',
      serverUrl: _serverUrlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      remotePath: _remotePathController.text.trim().isEmpty
          ? 'QNote'
          : _remotePathController.text.trim(),
      autoSync: _webdavEnabled,
      syncInterval: _webdavEnabled ? _syncInterval : 0,
      lastSyncTime: existing?.lastSyncTime,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await ref.read(webdavConfigProvider.notifier).saveConfig(config);
    await ConfigRepository.instance.setAppConfig('webdav_sync_on_launch', _syncOnLaunch ? 'true' : 'false');
    await ConfigRepository.instance.setAppConfig('webdav_sync_images', _syncImages ? 'true' : 'false');

    _updateInitialValues();

    if (!silent && mounted) {
      _showNotification('配置已保存', isSuccess: true);
    }
  }

  Future<void> _testConnection() async {
    final url = _serverUrlController.text.trim();
    final user = _usernameController.text.trim();
    final pwd = _passwordController.text;

    if (url.isEmpty || user.isEmpty || pwd.isEmpty) {
      _showNotification('请完整填写服务器地址、账号和密码', isError: true);
      return;
    }

    setState(() => _testing = true);
    try {
      final tempConfig = WebdavConfig(
        id: 'temp',
        serverUrl: url,
        username: user,
        password: pwd,
        remotePath: _remotePathController.text.trim().isEmpty
            ? 'QNote'
            : _remotePathController.text.trim(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      WebdavService.instance.updateConfig(tempConfig);
      final success = await WebdavService.instance.testConnection();
      if (mounted) {
        if (success) {
          _showNotification('连接成功！配置已自动保存', isSuccess: true);
          await _saveConfig(silent: true);
        } else {
          _showNotification('连接失败，请检查服务器地址与账号密码', isError: true);
        }
      }
    } catch (e) {
      if (mounted) {
        _showNotification('连接测试出错: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _performSync() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      _showNotification('请先配置并保存 WebDAV 服务器信息', isError: true);
      return;
    }

    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.performSync();

    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      final sizeInfo = scheduler.lastSyncSizeBytes != null
          ? ' (${(scheduler.lastSyncSizeBytes! / 1024).toStringAsFixed(1)}KB)'
          : '';
      _showNotification('同步成功！$sizeInfo', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('同步失败: ${scheduler.lastError ?? "请查看运行日志"}', isError: true);
    }
  }

  Future<void> _performFullSync() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      _showNotification('请先配置并保存 WebDAV 服务器信息', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('强制全量同步'),
        content: const Text('将把本地完整数据快照强制上传并覆盖云端快照，可能耗时稍长。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认同步'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.fullSync();

    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      _showNotification('全量同步成功！', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('全量同步失败: ${scheduler.lastError ?? "请查看日志"}', isError: true);
    }
  }

  Future<void> _cleanupOldBackups() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      _showNotification('请先配置并保存 WebDAV 服务器信息', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理旧备份文件'),
        content: const Text('将清理云端历史遗留的按日期命名的旧格式备份文件，保留最新的快照与增量数据。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    WebdavService.instance.updateConfig(config);
    final deletedCount = await SyncScheduler.instance.cleanupRemoteBackups();

    if (!mounted) return;
    _showNotification('已清理 $deletedCount 个旧备份文件', isSuccess: true);
  }

  Future<void> _restoreFromBackup() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      _showNotification('请先配置并保存 WebDAV 服务器信息', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从云端恢复本地数据', style: TextStyle(color: Colors.red)),
        content: const Text(
          '警告：此操作将从云端下载最新备份，并完全覆盖当前的本地数据！\n适用于换机或重新安装应用时的恢复。确认要继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认覆盖恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.restoreFromBackup();

    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      // 恢复成功后主动失效并刷新所有相关 Provider
      ref.invalidate(diaryListProvider);
      ref.invalidate(noteListProvider);
      ref.invalidate(todoListProvider);
      ref.invalidate(folderListProvider);
      ref.invalidate(aiConfigListProvider);
      ref.invalidate(aiRolesProvider);
      ref.invalidate(aiTemperaturesProvider);
      ref.invalidate(shortcutListProvider);
      ref.invalidate(userProfileProvider);
      ref.invalidate(chatSessionListProvider);
      ref.invalidate(webdavConfigProvider);
      ref.invalidate(diaryColorMarkProvider);

      _showNotification('本地数据已成功从云端恢复！', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('恢复失败: ${scheduler.lastError ?? "请确认云端是否存在有效备份"}', isError: true);
    }
  }

  String _statusText(SyncStatus status) {
    final progress = SyncScheduler.instance.currentProgressStatus;
    if (progress != null) return progress;
    return switch (status) {
      SyncStatus.idle => '空闲就绪',
      SyncStatus.syncing => '正在同步...',
      SyncStatus.success => '同步成功',
      SyncStatus.error => '同步失败',
    };
  }

  IconData _statusIcon(SyncStatus status) {
    return switch (status) {
      SyncStatus.idle => Icons.cloud_outlined,
      SyncStatus.syncing => Icons.sync,
      SyncStatus.success => Icons.cloud_done,
      SyncStatus.error => Icons.cloud_off,
    };
  }

  Color _statusColor(SyncStatus status, ColorScheme colorScheme) {
    return switch (status) {
      SyncStatus.idle => colorScheme.outline,
      SyncStatus.syncing => colorScheme.primary,
      SyncStatus.success => Colors.green,
      SyncStatus.error => colorScheme.error,
    };
  }

  String _formatCompactLastSyncTime(DateTime dateTime) {
    final now = DateTime.now();
    final timeStr = '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    if (dateTime.year == now.year && dateTime.month == now.month && dateTime.day == now.day) {
      return '今天 $timeStr';
    }
    return '${dateTime.month}/${dateTime.day} $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final syncStatus = SyncScheduler.instance.status;
    final lastSyncTime = SyncScheduler.instance.lastSyncTime;
    final lastError = SyncScheduler.instance.lastError;
    final isSyncing = syncStatus == SyncStatus.syncing;

    return PopScope(
      canPop: !_hasUnsavedChanges(),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _showUnsavedChangesDialog();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest,
        appBar: AppBar(
          title: const Text('同步设置'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (_hasUnsavedChanges()) {
                final shouldPop = await _showUnsavedChangesDialog();
                if (shouldPop && context.mounted) {
                  Navigator.of(context).pop();
                }
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton(
                onPressed: () => _saveConfig(),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 服务器配置卡片（最顶层）
              _buildServerConfigCard(context),

              const SizedBox(height: 16),

              // 2. 同步偏好设置卡片（精简后的开关）
              _buildSyncPreferencesCard(context),

              const SizedBox(height: 16),

              // 3. 同步状态概览与立即同步主操作卡片
              _buildSyncActionCard(
                context,
                syncStatus: syncStatus,
                lastSyncTime: lastSyncTime,
                lastError: lastError,
                isSyncing: isSyncing,
              ),

              const SizedBox(height: 16),

              // 4. 高级维护与数据恢复（折叠收拢）
              _buildAdvancedMaintenanceCard(context, isSyncing: isSyncing),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  /// 1. 服务器配置卡片
  Widget _buildServerConfigCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.dns_rounded, color: colorScheme.primary, size: 18),
              ),
              const SizedBox(width: 10),
              Text(
                'WebDAV 服务器',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              // 内嵌连接测试按钮
              OutlinedButton.icon(
                onPressed: _testing ? null : _testConnection,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.5)),
                ),
                icon: _testing
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                        ),
                      )
                    : Icon(Icons.wifi_tethering, size: 14, color: colorScheme.primary),
                label: Text(
                  _testing ? '测试中' : '测试连接',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildInputField(
            label: '服务器地址',
            hint: '如 https://dav.jianguoyun.com/dav/',
            controller: _serverUrlController,
          ),
          const SizedBox(height: 12),
          _buildInputField(
            label: '账号',
            hint: 'WebDAV 用户名或邮箱',
            controller: _usernameController,
          ),
          const SizedBox(height: 12),
          _buildInputField(
            label: '应用密码',
            hint: '授权密码或专有应用密码',
            controller: _passwordController,
            isPassword: true,
            obscure: _obscurePassword,
            onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
          ),
          const SizedBox(height: 10),
          // 路径高级设置：折叠显示，减少初学者负担
          InkWell(
            onTap: () => setState(() => _showAdvancedPath = !_showAdvancedPath),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _showAdvancedPath ? Icons.arrow_drop_down_rounded : Icons.arrow_right_rounded,
                    size: 20,
                    color: theme.hintColor,
                  ),
                  Text(
                    '备份存储目录: ${_remotePathController.text.trim().isEmpty ? 'QNote' : _remotePathController.text.trim()}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                  const Spacer(),
                  Text(
                    _showAdvancedPath ? '收起' : '修改',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showAdvancedPath) ...[
            const SizedBox(height: 8),
            _buildInputField(
              label: '远程根目录名称',
              hint: '默认为 QNote',
              controller: _remotePathController,
            ),
          ],
        ],
      ),
    );
  }

  /// 2. 同步选项配置卡片（合并与简化）
  Widget _buildSyncPreferencesCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          // 自动同步（主开关）：启用时默认打开启动同步并设置 15 分钟后台轮询
          _buildSettingRow(
            icon: Icons.autorenew_rounded,
            iconColor: colorScheme.primary,
            title: '自动同步',
            description: _webdavEnabled
                ? '启动应用以及每 ${_syncInterval > 0 ? "$_syncInterval 分钟" : "一段时间"} 后台自动同步'
                : '开启后将在应用启动与后台运行期间自动同步',
            trailing: Switch(
              value: _webdavEnabled,
              onChanged: (val) {
                setState(() {
                  _webdavEnabled = val;
                  if (val) {
                    _syncOnLaunch = true;
                    if (_syncInterval <= 0) _syncInterval = 15;
                  }
                });
              },
            ),
          ),

          // 若开启自动同步，允许微调间隔时间
          if (_webdavEnabled) ...[
            const Divider(height: 1, indent: 56, endIndent: 16),
            _buildSettingRow(
              icon: Icons.schedule_rounded,
              iconColor: colorScheme.primary,
              title: '同步频率',
              description: '应用在后台运行时的自动同步轮询周期',
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _syncIntervalOptions.any((e) => e.value == _syncInterval)
                      ? _syncInterval
                      : 15,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: colorScheme.onSurface,
                  ),
                  isDense: true,
                  items: _syncIntervalOptions
                      .map((e) => DropdownMenuItem(
                            value: e.value,
                            child: Text(e.key, style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _syncInterval = val);
                  },
                ),
              ),
            ),
          ],

          const Divider(height: 1, indent: 56, endIndent: 16),

          // 同步附件图片开关
          _buildSettingRow(
            icon: Icons.photo_library_outlined,
            iconColor: colorScheme.primary,
            title: '同步附件图片',
            description: '备份与同步日记、笔记中的插图文件',
            trailing: Switch(
              value: _syncImages,
              onChanged: (val) => setState(() => _syncImages = val),
            ),
          ),
        ],
      ),
    );
  }

  /// 3. 同步状态与立即同步操作卡片
  Widget _buildSyncActionCard(
    BuildContext context, {
    required SyncStatus syncStatus,
    required DateTime? lastSyncTime,
    required String? lastError,
    required bool isSyncing,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = _statusColor(syncStatus, colorScheme);

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          // 状态信息行
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(_statusIcon(syncStatus), color: statusColor, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '同步状态：',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.hintColor,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _statusText(syncStatus),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lastSyncTime != null
                          ? '上次同步：${_formatCompactLastSyncTime(lastSyncTime)}'
                          : '尚未同步过数据',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (syncStatus == SyncStatus.error && lastError != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      lastError,
                      style: TextStyle(color: colorScheme.error, fontSize: 11),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // 核心主按钮：立即同步
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: isSyncing ? null : _performSync,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.sync_rounded, size: 20),
              label: Text(
                isSyncing ? '同步处理中...' : '立即同步',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 4. 高级维护与数据恢复（折叠收拢）
  Widget _buildAdvancedMaintenanceCard(BuildContext context, {required bool isSyncing}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Icon(Icons.tune_rounded, color: theme.hintColor, size: 20),
          title: Text(
            '高级选项与数据恢复',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.hintColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          childrenPadding: const EdgeInsets.only(bottom: 12),
          children: [
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              dense: true,
              leading: Icon(Icons.cloud_upload_outlined, color: colorScheme.primary, size: 20),
              title: const Text('强制全量同步', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text('忽略本地增量，重新上传完整数据快照', style: TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: isSyncing ? null : _performFullSync,
            ),
            const Divider(height: 1, indent: 56, endIndent: 16),
            ListTile(
              dense: true,
              leading: Icon(Icons.cleaning_services_outlined, color: colorScheme.primary, size: 20),
              title: const Text('清理旧备份文件', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text('清理云端早期历史格式备份，释放网盘空间', style: TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: isSyncing ? null : _cleanupOldBackups,
            ),
            const Divider(height: 1, indent: 56, endIndent: 16),
            ListTile(
              dense: true,
              leading: Icon(Icons.settings_backup_restore_rounded, color: Colors.red.shade400, size: 20),
              title: Text(
                '从云端恢复到本地',
                style: TextStyle(color: Colors.red.shade400, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('从云端下载并覆盖本地数据（换机或重新安装时使用）', style: TextStyle(fontSize: 11)),
              trailing: Icon(Icons.chevron_right, size: 18, color: Colors.red.shade300),
              onTap: isSyncing ? null : _restoreFromBackup,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required Widget trailing,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }

  Widget _buildInputField({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool isPassword = false,
    bool obscure = false,
    VoidCallback? onToggleObscure,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.hintColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
            ),
            suffixIcon: isPassword
                ? IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 18,
                    ),
                    onPressed: onToggleObscure,
                  )
                : null,
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
