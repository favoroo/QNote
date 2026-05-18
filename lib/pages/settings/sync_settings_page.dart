import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/providers/sync_provider.dart' hide SyncStatus;
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/core/network/webdav_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:uuid/uuid.dart';

class SyncSettingsPage extends ConsumerStatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  ConsumerState<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends ConsumerState<SyncSettingsPage> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _remotePathController = TextEditingController();

  bool _obscurePassword = true;
  bool _webdavEnabled = false;
  bool _syncOnLaunch = false;
  int _syncInterval = 0;
  bool _testing = false;
  StreamSubscription<SyncStatus>? _statusSubscription;

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

      if (config != null) {
        _serverUrlController.text = config.serverUrl;
        _usernameController.text = config.username;
        _passwordController.text = config.password;
        _remotePathController.text = config.remotePath;
        setState(() {
          _webdavEnabled = config.autoSync;
          _syncOnLaunch = syncOnLaunch;
          _syncInterval = config.syncInterval;
        });
      } else {
        _remotePathController.text = 'QNote';
        setState(() {
          _webdavEnabled = false;
          _syncOnLaunch = syncOnLaunch;
          _syncInterval = 0;
        });
      }
    } catch (e) {
      _remotePathController.text = 'QNote';
    }
  }

  void _showNotification(String message, {bool isError = false, bool isSuccess = false}) {
    if (!mounted) return;
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    final theme = Theme.of(context);
    
    Color bgColor = theme.colorScheme.inverseSurface;
    Color textColor = theme.colorScheme.onInverseSurface;
    IconData? icon;
    
    if (isError) {
      bgColor = theme.colorScheme.errorContainer;
      textColor = theme.colorScheme.onErrorContainer;
      icon = Icons.error_outline;
    } else if (isSuccess) {
      bgColor = theme.colorScheme.primaryContainer;
      textColor = theme.colorScheme.onPrimaryContainer;
      icon = Icons.check_circle_outline;
    }
    
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: textColor, size: 20),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        elevation: 4,
        duration: const Duration(seconds: 3),
      ),
    );
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

    if (mounted) {
      _showNotification('配置已保存', isSuccess: true);
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
      _showNotification('云端同步成功！', isSuccess: true);
    } else if (scheduler.status == SyncStatus.error) {
      _showNotification('同步失败: ${scheduler.lastError ?? "请查看运行日志获取详情"}', isError: true);
    }
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

    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest.withValues(alpha: 0.5),
      appBar: AppBar(
        title: const Text('同步设置'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            // Sync Status Banner Card
            Container(
              margin: const EdgeInsets.only(bottom: 16),
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
            // Top Control Card
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
                  _buildSwitchTile(
                    icon: Icons.cloud_outlined,
                    iconColor: Colors.blue,
                    title: '启用 WebDAV 同步',
                    subtitle: '自动备份数据至私有网盘',
                    value: _webdavEnabled,
                    onChanged: (v) => setState(() => _webdavEnabled = v),
                  ),
                  const Divider(indent: 64, endIndent: 16, height: 1),
                  _buildSwitchTile(
                    icon: Icons.bolt_outlined,
                    iconColor: Colors.orange,
                    title: '启动时自动同步',
                    value: _syncOnLaunch,
                    onChanged: (v) => setState(() => _syncOnLaunch = v),
                  ),
                  const Divider(indent: 64, endIndent: 16, height: 1),
                  _buildDropdownTile(
                    icon: Icons.access_time,
                    iconColor: Colors.blueAccent,
                    title: '定期同步间隔',
                    value: _syncInterval,
                    options: _syncIntervalOptions,
                    onChanged: (v) {
                      if (v != null) setState(() => _syncInterval = v);
                    },
                  ),
                  if (lastSyncTime != null) ...[
                    const Divider(indent: 16, endIndent: 16, height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('最后同步时间', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                          Text(
                            '${lastSyncTime.year}/${lastSyncTime.month}/${lastSyncTime.day} ${lastSyncTime.hour}:${lastSyncTime.minute.toString().padLeft(2, '0')}:${lastSyncTime.second.toString().padLeft(2, '0')}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.hintColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Server Config Section
            _buildSectionHeader('服务器配置'),
            _buildInputField(
              label: '服务器地址',
              controller: _serverUrlController,
              hint: 'https://dav.jianguoyun.com/dav/',
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 8, bottom: 16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.orange.shade700),
                  const SizedBox(width: 4),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                        children: [
                          const TextSpan(text: '提示：'),
                          TextSpan(
                            text: '坚果云用户请务必在 URL 末尾包含 /dav/',
                            style: TextStyle(color: Colors.orange.shade700, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            _buildInputField(
              label: '账户',
              controller: _usernameController,
              hint: 'example@qq.com',
            ),
            const SizedBox(height: 16),
            _buildInputField(
              label: '应用密码',
              controller: _passwordController,
              hint: '••••••••••••••••',
              isPassword: true,
              obscure: _obscurePassword,
              onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
            const SizedBox(height: 16),
            _buildInputField(
              label: '备份子目录',
              controller: _remotePathController,
              hint: 'QNote',
            ),

            const SizedBox(height: 32),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: _testing
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                        : const Icon(Icons.wifi, size: 16),
                    label: Text(_testing ? '测试中...' : '连接测试', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: syncStatus == SyncStatus.syncing ? null : _performSync,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: theme.colorScheme.primaryContainer,
                      foregroundColor: theme.colorScheme.onPrimaryContainer,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: syncStatus == SyncStatus.syncing
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                        : const Icon(Icons.sync, size: 16),
                    label: const Text('手动同步', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: syncStatus == SyncStatus.syncing ? null : _restoreFromBackup,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  foregroundColor: Colors.red.shade400,
                ),
                icon: const Icon(Icons.settings_backup_restore, size: 20),
                label: const Text('从远程恢复本地数据'),
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).hintColor,
              fontWeight: FontWeight.bold,
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 28,
            child: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: value,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required int value,
    required List<MapEntry<String, int>> options,
    required ValueChanged<int?> onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
                ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: DropdownButtonHideUnderline(
              child: SizedBox(
                height: 28,
                child: DropdownButton<int>(
                  value: options.any((e) => e.value == value) ? value : 0,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 12),
                  isDense: true,
                  items: options
                      .map((e) => DropdownMenuItem(
                            value: e.value,
                            child: Text(e.key),
                          ))
                      .toList(),
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

}
