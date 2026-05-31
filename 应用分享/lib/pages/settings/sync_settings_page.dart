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
  bool _syncOnLaunch = false;
  bool _syncImages = false;
  int _syncInterval = 0;
  bool _testing = false;
  StreamSubscription<SyncStatus>? _statusSubscription;

  // 保存初始配置值，用于判断是否有未保存的更改
  String _initialServerUrl = '';
  String _initialUsername = '';
  String _initialPassword = '';
  String _initialRemotePath = '';
  bool _initialWebdavEnabled = false;
  bool _initialSyncOnLaunch = false;
  bool _initialSyncImages = false;
  int _initialSyncInterval = 0;

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



  static const _syncIntervalOptions = <MapEntry<String, int>>[
    MapEntry('关闭', 0),
    MapEntry('5分钟', 5),
    MapEntry('15分钟', 15),
    MapEntry('30分钟', 30),
    MapEntry('1小时', 60),
    MapEntry('6小时', 360),
  ];

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _statusSubscription = SyncScheduler.instance.statusStream.listen((status) {
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

  Future<void> _loadConfig() async {
    try {
      final config = await ref.read(webdavConfigProvider.future);
      final syncOnLaunchStr = await ConfigRepository.instance.getAppConfig('webdav_sync_on_launch');
      final syncOnLaunch = syncOnLaunchStr == 'true';
      final syncImagesStr = await ConfigRepository.instance.getAppConfig('webdav_sync_images');
      final syncImages = syncImagesStr == 'true';

      if (config != null) {
        _serverUrlController.text = config.serverUrl;
        _usernameController.text = config.username;
        _passwordController.text = config.password;
        _remotePathController.text = config.remotePath;
        setState(() {
          _webdavEnabled = config.autoSync;
          _syncOnLaunch = syncOnLaunch;
          _syncImages = syncImages;
          _syncInterval = config.syncInterval;
        });
      } else {
        _remotePathController.text = 'QNote';
        setState(() {
          _webdavEnabled = false;
          _syncOnLaunch = syncOnLaunch;
          _syncImages = syncImages;
          _syncInterval = 0;
        });
      }
      _updateInitialValues();
    } catch (e) {
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

  Future<void> _saveConfig() async {
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
      syncInterval: _syncInterval,
      lastSyncTime: existing?.lastSyncTime,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await ref.read(webdavConfigProvider.notifier).saveConfig(config);
    await ConfigRepository.instance.setAppConfig('webdav_sync_on_launch', _syncOnLaunch ? 'true' : 'false');
    await ConfigRepository.instance.setAppConfig('webdav_sync_images', _syncImages ? 'true' : 'false');

    _updateInitialValues();

    if (mounted) {
      _showNotification('配置已保存', isSuccess: true);
    }
  }

  Future<void> _performSyncImages() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null) {
      _showNotification('请先配置 WebDAV', isError: true);
      return;
    }
    WebdavService.instance.updateConfig(config);
    
    await SyncScheduler.instance.manuallySyncImages(
      onProgress: (status) {
        if (mounted) setState(() {});
      }
    );
    
    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      _showNotification('图片同步成功！', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('图片同步失败: ${scheduler.lastError ?? "请查看运行日志获取详情"}', isError: true);
    }
  }

  Future<void> _testConnection() async {
    if (_serverUrlController.text.trim().isEmpty ||
        _usernameController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      _showNotification('请完整填写服务器地址、账号和密码', isError: true);
      return;
    }

    setState(() => _testing = true);
    try {
      final tempConfig = WebdavConfig(
        id: 'temp',
        serverUrl: _serverUrlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        remotePath: _remotePathController.text.trim().isEmpty
            ? 'QNote'
            : _remotePathController.text.trim(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      WebdavService.instance.updateConfig(tempConfig);
      final success = await WebdavService.instance.testConnection();
      if (mounted) {
        _showNotification(
          success ? '连接成功！' : '连接失败，请检查配置',
          isSuccess: success,
          isError: !success,
        );
        if (success) {
          await _saveConfig();
        }
      }
    } catch (e) {
      if (mounted) {
        _showNotification('连接测试失败: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _performSync() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null) {
      _showNotification('请先配置 WebDAV', isError: true);
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
      final typeInfo = scheduler.lastSyncWasFull ? '全量同步' : '增量同步';
      _showNotification('$typeInfo成功！$sizeInfo', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('同步失败: ${scheduler.lastError ?? "请查看运行日志获取详情"}', isError: true);
    }
  }

  Future<void> _performFullSync() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null) {
      _showNotification('请先配置 WebDAV', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('强制全量同步'),
        content: const Text('将上传完整数据快照到云端，可能需要较长时间。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.fullSync();

    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      final sizeInfo = scheduler.lastSyncSizeBytes != null
          ? ' (${(scheduler.lastSyncSizeBytes! / 1024).toStringAsFixed(1)}KB)'
          : '';
      _showNotification('全量同步成功！$sizeInfo', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('全量同步失败: ${scheduler.lastError ?? "请查看运行日志获取详情"}', isError: true);
    }
  }

  Future<void> _cleanupOldBackups() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null) {
      _showNotification('请先配置 WebDAV', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理远程旧备份'),
        content: const Text('将删除云端所有旧格式的按日期命名的备份文件（qnote_backup_*.json），仅保留新格式的快照和增量文件。是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    WebdavService.instance.updateConfig(config);
    final deletedCount = await SyncScheduler.instance.cleanupRemoteBackups();

    if (!mounted) return;
    _showNotification('已清理 $deletedCount 个旧备份文件', isSuccess: true);
  }

  Future<void> _restoreFromBackup() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null) {
      _showNotification('请先配置 WebDAV', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从远程恢复'),
        content: const Text('此操作将从云端下载数据并覆盖本地数据，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.restoreFromBackup();

    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      // Refresh all providers to instantly reload the restored database in the UI!
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

      _showNotification('本地数据已成功恢复！', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('恢复失败: ${scheduler.lastError ?? "请确认云端是否存在备份文件，或查看运行日志"}', isError: true);
    }
  }

  String _statusText(SyncStatus status) {
    final progress = SyncScheduler.instance.currentProgressStatus;
    if (progress != null) return progress;
    return switch (status) {
      SyncStatus.idle => '空闲',
      SyncStatus.syncing => '同步中...',
      SyncStatus.success => '同步成功',
      SyncStatus.error => '同步失败',
    };
  }

  IconData _statusIcon(SyncStatus status) {
    return switch (status) {
      SyncStatus.idle => Icons.cloud_off,
      SyncStatus.syncing => Icons.sync,
      SyncStatus.success => Icons.cloud_done,
      SyncStatus.error => Icons.cloud_off,
    };
  }

  Color _statusColor(SyncStatus status) {
    return switch (status) {
      SyncStatus.idle => Colors.grey,
      SyncStatus.syncing => Colors.blue,
      SyncStatus.success => Colors.green,
      SyncStatus.error => Colors.red,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final syncStatus = SyncScheduler.instance.status;
    final lastSyncTime = SyncScheduler.instance.lastSyncTime;
    final lastError = SyncScheduler.instance.lastError;

    return PopScope(
      canPop: !_hasUnsavedChanges(),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _showUnsavedChangesDialog();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest.withValues(alpha: 0.5),
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
                  onPressed: _saveConfig,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Sync Status Banner Card
                Container(
                  margin: const EdgeInsets.only(bottom: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: _statusColor(syncStatus).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _statusColor(syncStatus).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _statusIcon(syncStatus),
                        color: _statusColor(syncStatus),
                        size: 20,
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
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _statusText(syncStatus),
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: _statusColor(syncStatus),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            if (syncStatus == SyncStatus.error && lastError != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                lastError,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.red.shade700,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Top Control Card (Sync Policies)
                Container(
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.02),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _buildSettingRow(
                        icon: Icons.sync_outlined,
                        iconColor: Colors.blue,
                        title: '自动同步',
                        description: '允许应用在后台按规则自动同步数据',
                        trailing: Switch(
                          value: _webdavEnabled,
                          onChanged: (v) => setState(() => _webdavEnabled = v),
                        ),
                      ),
                      const Divider(height: 1, indent: 56, endIndent: 16),
                      _buildSettingRow(
                        icon: Icons.bolt_outlined,
                        iconColor: Colors.orange,
                        title: '启动时自动同步',
                        description: '每次打开或进入应用时自动执行一次同步',
                        enabled: _webdavEnabled,
                        trailing: Switch(
                          value: _syncOnLaunch,
                          onChanged: _webdavEnabled
                              ? (v) => setState(() => _syncOnLaunch = v)
                              : null,
                        ),
                      ),
                      const Divider(height: 1, indent: 56, endIndent: 16),
                      _buildSettingRow(
                        icon: Icons.image_outlined,
                        iconColor: Colors.purple,
                        title: '同步图片',
                        description: '在进行数据同步时，同步日记与笔记中的图片文件',
                        trailing: Switch(
                          value: _syncImages,
                          onChanged: (v) => setState(() => _syncImages = v),
                        ),
                      ),
                      const Divider(height: 1, indent: 56, endIndent: 16),
                      _buildSettingRow(
                        icon: Icons.access_time_outlined,
                        iconColor: Colors.indigoAccent,
                        title: '自动同步间隔',
                        description: '设定应用运行期间自动同步的时间间隔',
                        enabled: _webdavEnabled,
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _syncIntervalOptions.any((e) => e.value == _syncInterval)
                                ? _syncInterval
                                : 0,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: _webdavEnabled ? colorScheme.onSurface : theme.disabledColor,
                            ),
                            isDense: true,
                            items: _syncIntervalOptions
                                .map((e) => DropdownMenuItem(
                                      value: e.value,
                                      child: Text(e.key, style: const TextStyle(fontSize: 13)),
                                    ))
                                .toList(),
                            onChanged: _webdavEnabled
                                ? (v) {
                                    if (v != null) setState(() => _syncInterval = v);
                                  }
                                : null,
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56, endIndent: 16),
                      _buildSettingRow(
                        icon: Icons.cloud_done_outlined,
                        iconColor: Colors.teal,
                        title: '上次同步时间',
                        description: '最近一次与云端成功同步数据的时间',
                        trailing: Text(
                          lastSyncTime != null
                              ? _formatCompactLastSyncTime(lastSyncTime)
                              : '未同步',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.hintColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Server Config Section Card
                Container(
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.02),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.dns_outlined, color: colorScheme.primary, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '服务器配置',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildInputField(
                        label: '服务器地址',
                        controller: _serverUrlController,
                      ),
                      const SizedBox(height: 16),
                      _buildInputField(
                        label: '账户',
                        controller: _usernameController,
                      ),
                      const SizedBox(height: 16),
                      _buildInputField(
                        label: '应用密码',
                        controller: _passwordController,
                        isPassword: true,
                        obscure: _obscurePassword,
                        onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                      const SizedBox(height: 16),
                      _buildInputField(
                        label: '备份子目录',
                        controller: _remotePathController,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Action Operations Card
                Container(
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.02),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 20, top: 20, right: 20, bottom: 8),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(Icons.construction_outlined, color: colorScheme.primary, size: 18),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '同步维护与操作',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildActionRow(
                          icon: Icons.wifi_protected_setup_outlined,
                          color: Colors.blue,
                          title: '连接测试',
                          desc: '检查当前配置能否成功连接 WebDAV 服务器',
                          onTap: _testing ? null : _testConnection,
                          isLoading: _testing,
                        ),
                        const Divider(height: 1, indent: 56, endIndent: 16),
                        _buildActionRow(
                          icon: Icons.sync,
                          color: Colors.green,
                          title: '手动同步',
                          desc: '对比本地与云端，执行增量数据同步合并',
                          onTap: syncStatus == SyncStatus.syncing ? null : _performSync,
                          isLoading: syncStatus == SyncStatus.syncing && SyncScheduler.instance.currentProgressStatus == null,
                        ),
                        const Divider(height: 1, indent: 56, endIndent: 16),
                        _buildActionRow(
                          icon: Icons.image_search_outlined,
                          color: Colors.purple,
                          title: '同步图片',
                          desc: '对比本地与云端，执行图片文件增删同步',
                          onTap: syncStatus == SyncStatus.syncing ? null : _performSyncImages,
                          isLoading: syncStatus == SyncStatus.syncing && SyncScheduler.instance.currentProgressStatus != null,
                        ),
                        const Divider(height: 1, indent: 56, endIndent: 16),
                        _buildActionRow(
                          icon: Icons.cloud_upload_outlined,
                          color: Colors.purple,
                          title: '全量同步',
                          desc: '忽略历史状态，强制上传完整数据快照到云端',
                          onTap: syncStatus == SyncStatus.syncing ? null : _performFullSync,
                        ),
                        const Divider(height: 1, indent: 56, endIndent: 16),
                        _buildActionRow(
                          icon: Icons.cleaning_services_outlined,
                          color: Colors.amber.shade700,
                          title: '清理旧备份',
                          desc: '清理云端冗余的旧格式备份文件，释放网盘空间',
                          onTap: syncStatus == SyncStatus.syncing ? null : _cleanupOldBackups,
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.red.withValues(alpha: 0.2),
                              ),
                            ),
                            child: InkWell(
                              onTap: syncStatus == SyncStatus.syncing ? null : _restoreFromBackup,
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.settings_backup_restore, size: 20, color: Colors.red.shade400),
                                    const SizedBox(width: 8),
                                    Text(
                                      '从远程恢复本地数据',
                                      style: TextStyle(
                                        color: Colors.red.shade400,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 40),
              ],
            ),
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
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 16),
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
            const SizedBox(width: 16),
            IgnorePointer(
              ignoring: !enabled,
              child: trailing,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow({
    required IconData icon,
    required Color color,
    required String title,
    required String desc,
    required VoidCallback? onTap,
    bool isLoading = false,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    )
                  : Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
                    desc,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: theme.hintColor.withValues(alpha: 0.5),
              size: 18,
            ),
          ],
        ),
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
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ),
        TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
            ),
            suffixIcon: isPassword
                ? IconButton(
                    icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
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

  String _formatCompactLastSyncTime(DateTime dateTime) {
    final now = DateTime.now();
    if (dateTime.year == now.year && dateTime.month == now.month && dateTime.day == now.day) {
      return '今天 ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    }
    return '${dateTime.month}/${dateTime.day} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}
