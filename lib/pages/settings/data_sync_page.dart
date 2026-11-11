import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/ai/account_auth_registry.dart';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/core/network/webdav_service.dart';
import 'package:qnote_flutter/core/storage/chat_image_gc.dart';
import 'package:qnote_flutter/core/storage/chat_storage_usage.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/pages/settings/sync_settings_page.dart';
import 'package:qnote_flutter/providers/agent_memory_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/daily_score_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/fixed_event_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/quick_prompt_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/sync_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/widgets/log_viewer_page.dart';
import 'package:qnote_flutter/widgets/settings_segment_bar.dart';

/// 数据与同步页面
///
/// 将原先分散的「数据管理」与「同步设置」合并为统一入口，按操作性质分三个分区：
/// - 云同步：WebDAV 配置与日常同步（高频）；
/// - 备份与恢复：JSON 导出导入、云端恢复（低频、搬家场景）；
/// - 维护与诊断：全量同步、旧备份清理、日志、清空数据（低频、含高危操作）。
///
/// 分区切换与页面返回都会校验「云同步」的未保存配置，避免误改丢失。
class DataSyncPage extends ConsumerStatefulWidget {
  const DataSyncPage({super.key, this.initialTab = 0});

  /// 初始分区索引：0 云同步 / 1 备份与恢复 / 2 维护与诊断
  final int initialTab;

  @override
  ConsumerState<DataSyncPage> createState() => _DataSyncPageState();
}

class _DataSyncPageState extends ConsumerState<DataSyncPage> {
  static const _tabItems = <SettingsSegmentItem>[
    SettingsSegmentItem(title: '云同步', icon: Icons.cloud_sync_outlined),
    SettingsSegmentItem(title: '备份恢复', icon: Icons.settings_backup_restore_rounded),
    SettingsSegmentItem(title: '维护诊断', icon: Icons.build_outlined),
  ];

  late int _currentIndex;
  final _syncKey = GlobalKey<SyncSettingsViewState>();
  bool _syncDirty = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab.clamp(0, _tabItems.length - 1);
  }

  /// 切换分区；云同步存在未保存改动时先确认，用户取消则留在原分区
  Future<void> _switchTo(int index) async {
    if (index == _currentIndex) return;
    if (_syncDirty) {
      final canLeave = await _syncKey.currentState?.confirmUnsavedChanges() ?? true;
      if (!canLeave) return;
    }
    if (!mounted) return;
    setState(() => _currentIndex = index);
  }

  Future<void> _saveSyncConfig() async {
    await _syncKey.currentState?.saveConfig();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: !_syncDirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final canLeave = await _syncKey.currentState?.confirmUnsavedChanges() ?? true;
        if (!canLeave) return;
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest,
        appBar: AppBar(
          title: const Text('数据与同步'),
          centerTitle: false,
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            // 仅在云同步分区存在未保存改动时出现，避免常态占位
            if (_syncDirty)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: FilledButton(
                  onPressed: _saveSyncConfig,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            SettingsSegmentBar(items: _tabItems, selectedIndex: _currentIndex, onChanged: _switchTo),
            Expanded(
              child: SettingsSegmentContent(
                index: _currentIndex,
                child: IndexedStack(
                  index: _currentIndex,
                  children: [
                    SyncSettingsView(
                      key: _syncKey,
                      onDirtyChanged: (dirty) {
                        if (_syncDirty == dirty) return;
                        setState(() => _syncDirty = dirty);
                      },
                    ),
                    const _BackupRestoreTab(),
                    const _MaintenanceTab(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数据被整体替换后（导入 / 云端恢复 / 清空），刷新所有相关 Provider。
///
/// 两个 Tab 都会触发整体替换，因此放在文件级共用，避免两边清单不一致。
void _invalidateAllData(WidgetRef ref) {
  ref.invalidate(diaryListProvider);
  ref.invalidate(noteListProvider);
  ref.invalidate(todoListProvider);
  ref.invalidate(folderListProvider);
  ref.invalidate(aiProviderListProvider);
  ref.invalidate(aiRouteGroupListProvider);
  ref.invalidate(aiRolesProvider);
  ref.invalidate(aiTemperaturesProvider);
  ref.invalidate(shortcutListProvider);
  ref.invalidate(userProfileProvider);
  ref.invalidate(chatSessionListProvider);
  ref.invalidate(webdavConfigProvider);
  ref.invalidate(diaryColorMarkProvider);
  // 固定事件模板、每日评分、快捷提示、智能体记忆也都在备份/清空的覆盖范围内，
  // 漏刷新的表现是清空后这些列表仍显示旧内容。
  ref.invalidate(fixedEventListProvider);
  ref.invalidate(fixedEventNotifierProvider);
  ref.invalidate(dailyScoreProvider);
  ref.invalidate(dailyScoreHistoryProvider);
  ref.invalidate(dailyScoreHeatmapProvider);
  ref.invalidate(quickPromptListProvider);
  ref.invalidate(agentMemoryListProvider);
  // 清空/恢复后订阅登录态可能已被清掉，进程内缓存不能继续用
  AccountAuthRegistry.clearAllCaches();
}

/// 备份与恢复分区：本地 JSON 导出导入、云端恢复
class _BackupRestoreTab extends ConsumerStatefulWidget {
  const _BackupRestoreTab();

  @override
  ConsumerState<_BackupRestoreTab> createState() => _BackupRestoreTabState();
}

class _BackupRestoreTabState extends ConsumerState<_BackupRestoreTab> {
  final ExportService _exportService = ExportService();

  bool _isExporting = false;
  bool _isImporting = false;
  bool _isRestoring = false;

  Future<void> _handleExport() async {
    setState(() => _isExporting = true);
    try {
      final jsonStr = await _exportService.exportAllToJson();
      await _exportService.shareJson(jsonStr);
      if (mounted) {
        Toast.success(context, '导出成功');
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context, '导出失败');
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleImport() async {
    // 同步进行中导入会与上传线程互相覆盖：上传可能正把旧快照推上去，
    // 而导入又把本地换成另一份数据。
    if (SyncScheduler.instance.status == SyncStatus.syncing) {
      Toast.warning(context, '同步中，稍后再导入');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入数据'),
        content: const Text('将覆盖当前本地数据。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('继续')),
        ],
      ),
    );
    if (confirmed != true) return;

    if (!mounted) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: '选择 JSON 备份文件',
      withData: true,
    );
    if (result == null) return;
    final file = result.files.single;

    setState(() => _isImporting = true);
    try {
      if (kIsWeb) {
        if (file.bytes == null) {
          throw Exception('无法读取文件内容 (bytes is null)');
        }
        final jsonStr = utf8.decode(file.bytes!);
        await _exportService.importFromJsonString(jsonStr);
      } else {
        final filePath = file.path;
        if (filePath == null) {
          throw Exception('无法获取文件路径');
        }
        await _exportService.importFromJson(filePath.trim());
      }
      if (mounted) {
        _invalidateAllData(ref);
        Toast.success(context, '导入成功');
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logImport(
        '数据导入失败',
        level: LogLevel.error,
        details: '${e.toString()}\n堆栈: ${stackTrace.toString()}',
      );
      if (mounted) {
        Toast.error(context, '导入失败');
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// 从云端下载最新备份并覆盖本地数据
  Future<void> _handleRestoreFromCloud() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      Toast.error(context, '请先配置并保存 WebDAV 服务器');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从云端恢复', style: TextStyle(color: Colors.red)),
        content: const Text('将用云端备份覆盖本地数据，不可撤销。\n换机或重装后恢复时使用。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('覆盖恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRestoring = true);
    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.restoreFromBackup();
    if (!mounted) return;
    setState(() => _isRestoring = false);

    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      _invalidateAllData(ref);
      Toast.success(context, '云端恢复成功');
    } else if (scheduler.status == SyncStatus.error) {
      Toast.error(context, '恢复失败：${scheduler.lastError ?? "请确认云端有可用备份"}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _SectionTitle(title: '本地备份', theme: theme),
        _ActionGroup(
          children: [
            _ActionTile(
              icon: Icons.file_download_outlined,
              title: '导出 JSON 备份',
              onTap: _isExporting ? null : _handleExport,
              isLoading: _isExporting,
            ),
            _ActionTile(
              icon: Icons.file_upload_outlined,
              title: '导入备份',
              onTap: _isImporting ? null : _handleImport,
              isLoading: _isImporting,
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle(title: '云端恢复', theme: theme),
        _ActionGroup(
          children: [
            _ActionTile(
              icon: Icons.settings_backup_restore_rounded,
              title: '从云端恢复',
              color: Colors.orange.shade700,
              onTap: _isRestoring ? null : _handleRestoreFromCloud,
              isLoading: _isRestoring,
            ),
          ],
        ),
      ],
    );
  }
}

/// 维护与诊断分区：同步运维、日志查看与高危清空
class _MaintenanceTab extends ConsumerStatefulWidget {
  const _MaintenanceTab();

  @override
  ConsumerState<_MaintenanceTab> createState() => _MaintenanceTabState();
}

class _MaintenanceTabState extends ConsumerState<_MaintenanceTab> {
  StreamSubscription<SyncStatus>? _statusSubscription;
  bool _isClearing = false;

  /// 对话历史占用（只读估算，进入维护页时拉一次，回收/整理后刷新）
  ChatStorageUsage? _chatUsage;
  bool _isReclaiming = false;
  bool _isVacuuming = false;

  @override
  void initState() {
    super.initState();
    _statusSubscription = SyncScheduler.instance.statusStream.listen((_) {
      if (mounted) setState(() {});
    });
    _loadChatUsage();
  }

  Future<void> _loadChatUsage() async {
    try {
      final usage = await ConfigRepository.instance.estimateChatStorageUsage();
      if (mounted) setState(() => _chatUsage = usage);
    } catch (e) {
      // 估算失败不影响本页其它功能，保持为 null 即可
      LoggerService.instance.logDatabase('统计对话存储占用失败', details: e.toString(), level: LogLevel.warning);
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

  Future<void> _performFullSync() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      Toast.error(context, '请先配置并保存 WebDAV 服务器');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('强制全量同步'),
        content: const Text('将用本地数据覆盖云端快照，耗时较长。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('确认同步')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    WebdavService.instance.updateConfig(config);
    await SyncScheduler.instance.fullSync();

    if (!mounted) return;
    final scheduler = SyncScheduler.instance;
    if (scheduler.status == SyncStatus.success) {
      Toast.success(context, '全量同步完成');
    } else if (scheduler.status == SyncStatus.error) {
      Toast.error(context, '全量同步失败：${scheduler.lastError ?? "请查看日志"}');
    }
  }

  Future<void> _cleanupOldBackups() async {
    final config = await ref.read(webdavConfigProvider.future).catchError((_) => null);
    if (!mounted) return;
    if (config == null || config.serverUrl.isEmpty) {
      Toast.error(context, '请先配置并保存 WebDAV 服务器');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理旧备份文件'),
        content: const Text('将清理云端按日期命名的旧格式备份，保留最新快照与增量数据。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('清理')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    WebdavService.instance.updateConfig(config);
    final deletedCount = await SyncScheduler.instance.cleanupRemoteBackups();

    if (!mounted) return;
    Toast.success(context, '已清理 $deletedCount 个旧备份');
  }

  void _openLogViewer() {
    Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const LogViewerPage()));
  }

  Future<void> _handleClearData() async {
    // 同步进行中清库会让远端与本地互相覆盖：上传线程可能正在把清空前/清空后的
    // 半截状态推上去，下一次拉取又把旧数据写回来。
    if (SyncScheduler.instance.status == SyncStatus.syncing) {
      Toast.warning(context, '同步中，稍后再清空');
      return;
    }

    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除数据'),
        content: const Text('将删除全部本地数据，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (firstConfirm != true) return;

    if (!mounted) return;
    final secondConfirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('再次确认'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (secondConfirm != true) return;

    setState(() => _isClearing = true);
    try {
      // 表清单、磁盘图片、SharedPreferences 统一由 ExportService 处理，
      // 避免这里和导入覆盖各自维护一份后漏表（历史漏过 ai_providers）。
      final deletedImages = await ExportService().wipeAllLocalData();
      await _loadChatUsage();
      if (!mounted) return;
      // 不刷新 Provider 的话界面仍显示旧数据，用户会以为没清干净。
      _invalidateAllData(ref);
      Toast.success(context, deletedImages > 0 ? '已清除（含 $deletedImages 张图片）' : '已清除');
    } catch (e, stackTrace) {
      LoggerService.instance.logDatabase('清空本地数据失败', level: LogLevel.error, details: '${e.toString()}\n$stackTrace');
      if (mounted) {
        Toast.error(context, '清除失败');
      }
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  /// 对话历史占用摘要行（只读估算，点击可刷新）。
  String _chatUsageSubtitle(ChatStorageUsage? usage) {
    if (usage == null) {
      return '统计中…';
    }
    final parts = <String>[
      '${usage.activeSessions} 个对话 · 消息 ${formatChatStorageBytes(usage.activeMessagesBytes)}',
      if (usage.aiImageFiles > 0) '生成图 ${usage.aiImageFiles} 张 ${formatChatStorageBytes(usage.aiImageBytes)}',
      if (usage.databaseFileBytes != null) '库文件 ${formatChatStorageBytes(usage.databaseFileBytes!)}',
    ];
    if (usage.tombstonedSessions > 0 || usage.orphanImageFiles > 0) {
      parts.add('待回收 ${formatChatStorageBytes(usage.reclaimableBytes)}');
    }
    return parts.join(' · ');
  }

  /// 立即回收：清掉旧版本软删除留下的对话墓碑，以及已无对话引用的生成图片。
  ///
  /// 只做「删掉无人引用的东西」，不触碰仍在显示的对话与笔记/日记在用的文件。
  Future<void> _reclaimChatStorage() async {
    if (SyncScheduler.instance.status == SyncStatus.syncing) {
      Toast.warning(context, '同步中，稍后再回收');
      return;
    }
    final usage = _chatUsage;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('立即回收'),
        content: Text(
          '将永久删除旧版遗留的 ${usage?.tombstonedSessions ?? 0} 个已删对话'
          '和 ${usage?.orphanImageFiles ?? 0} 张无引用生成图，当前可见的笔记与日记不受影响。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('回收')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isReclaiming = true);
    try {
      final purged = await ConfigRepository.instance.purgeTombstonedChatSessions();
      final orphans = await ChatImageGc.instance.deleteUnreferencedAiImages();
      final bytes = purged.imageFreedBytes + orphans.freedBytes;
      ref.invalidate(chatSessionListProvider);
      await _loadChatUsage();
      if (!mounted) return;

      if (purged.deletedSessions == 0 && orphans.deletedFiles == 0) {
        Toast.success(context, '无需回收');
      } else {
        Toast.success(
          context,
          '已回收 ${purged.deletedSessions} 个对话 · '
          '${orphans.deletedFiles} 张图片'
          '${bytes > 0 ? ' · 释放约 ${formatChatStorageBytes(bytes)}' : ''}',
        );
      }
    } catch (e) {
      if (mounted) Toast.error(context, '回收失败');
      LoggerService.instance.logDatabase('对话存储回收失败', details: e.toString(), level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _isReclaiming = false);
    }
  }

  /// 整理数据库（VACUUM）：删行不会让 SQLite 文件变小，只有整理才真正把空间还给系统。
  Future<void> _vacuumDatabase() async {
    if (kIsWeb) {
      Toast.info(context, 'Web 端存储由浏览器管理');
      return;
    }
    if (SyncScheduler.instance.status == SyncStatus.syncing) {
      Toast.warning(context, '同步中，稍后再整理');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('整理数据库'),
        content: const Text('将重写数据库文件以释放空间，需约 2 倍库文件的临时空间，期间请勿同步。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('整理')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isVacuuming = true);
    final ok = await ConfigRepository.instance.vacuumDatabase();
    await _loadChatUsage();
    if (!mounted) return;
    setState(() => _isVacuuming = false);
    if (ok) {
      Toast.success(context, '整理完成');
    } else {
      Toast.info(context, '当前平台不支持整理');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isSyncing = SyncScheduler.instance.status == SyncStatus.syncing;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _SectionTitle(title: '同步维护', theme: theme),
        _ActionGroup(
          children: [
            _ActionTile(icon: Icons.cloud_upload_outlined, title: '强制全量同步', onTap: isSyncing ? null : _performFullSync),
            _ActionTile(
              icon: Icons.cleaning_services_outlined,
              title: '清理旧备份文件',
              color: Colors.teal.shade600,
              onTap: isSyncing ? null : _cleanupOldBackups,
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle(title: '对话存储', theme: theme),
        _ActionGroup(
          children: [
            _ActionTile(
              icon: Icons.storage_rounded,
              title: '对话存储占用',
              subtitle: _chatUsageSubtitle(_chatUsage),
              color: colorScheme.onSurfaceVariant,
              onTap: () => _loadChatUsage(),
            ),
            _ActionTile(
              icon: Icons.delete_sweep_rounded,
              title: '立即回收',
              subtitle: '清除旧版遗留对话与无引用图片',
              onTap: (_isReclaiming || isSyncing) ? null : _reclaimChatStorage,
              isLoading: _isReclaiming,
            ),
            _ActionTile(
              icon: Icons.bolt_rounded,
              title: '整理数据库',
              subtitle: '回收已删除内容占用的空间',
              onTap: (_isVacuuming || isSyncing) ? null : _vacuumDatabase,
              isLoading: _isVacuuming,
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle(title: '诊断', theme: theme),
        _ActionGroup(
          children: [
            _ActionTile(
              icon: Icons.terminal_rounded,
              title: '查看运行日志',
              color: colorScheme.onSurfaceVariant,
              onTap: _openLogViewer,
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle(title: '危险操作', theme: theme),
        _ActionGroup(
          children: [
            _ActionTile(
              icon: Icons.delete_outline_rounded,
              title: '清空本地数据',
              color: colorScheme.error,
              isDestructive: true,
              onTap: _isClearing ? null : _handleClearData,
              isLoading: _isClearing,
            ),
          ],
        ),
      ],
    );
  }
}

/// 分区标题
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.theme});

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

/// 操作卡片容器
class _ActionGroup extends StatelessWidget {
  const _ActionGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final List<Widget> dividedChildren = [];
    for (int i = 0; i < children.length; i++) {
      dividedChildren.add(children[i]);
      if (i < children.length - 1) {
        dividedChildren.add(
          Divider(
            height: 1,
            thickness: 0.8,
            indent: 64,
            endIndent: 16,
            color: colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
        );
      }
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(children: dividedChildren),
    );
  }
}

/// 单个操作项
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.color,
    this.isDestructive = false,
    this.isLoading = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  /// 次要说明行（如存储占用数字）：为空时保持原有单行高度
  final String? subtitle;
  final Color? color;
  final bool isDestructive;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final effectiveColor = color ?? (isDestructive ? colorScheme.error : colorScheme.primary);
    final enabled = onTap != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              // 精致图标徽标
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: enabled ? 0.1 : 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: effectiveColor.withValues(alpha: enabled ? 1.0 : 0.4), size: 20),
              ),
              const SizedBox(width: 14),
              // 文本区域
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: isDestructive
                            ? effectiveColor.withValues(alpha: enabled ? 1.0 : 0.5)
                            : colorScheme.onSurface.withValues(alpha: enabled ? 1.0 : 0.5),
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.35),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 状态尾部
              if (isLoading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(effectiveColor)),
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  color: (isDestructive ? effectiveColor : colorScheme.onSurfaceVariant).withValues(
                    alpha: enabled ? 0.4 : 0.2,
                  ),
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
