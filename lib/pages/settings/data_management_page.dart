import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DataManagementPage extends ConsumerStatefulWidget {
  const DataManagementPage({super.key});

  @override
  ConsumerState<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends ConsumerState<DataManagementPage> {
  final ExportService _exportService = ExportService();

  bool _isExporting = false;
  bool _isImporting = false;

  Future<void> _handleExport() async {
    setState(() => _isExporting = true);
    try {
      final jsonStr = await _exportService.exportAllToJson();
      await _exportService.shareJson(jsonStr);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('数据导出成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleImport() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入数据'),
        content: const Text('导入将覆盖当前数据，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续'),
          ),
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
        // 刷新所有 providers 以加载新导入的数据
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('数据导入成功')),
        );
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logImport(
        '数据导入失败',
        level: LogLevel.error,
        details: '${e.toString()}\n堆栈: ${stackTrace.toString()}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  void _showLogViewer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _LogViewerPage(),
      ),
    );
  }

  Future<void> _handleClearData() async {
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除数据'),
        content: const Text('确定要清除所有数据吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
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
        content: const Text('此操作不可恢复，再次确认清除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (secondConfirm != true) return;

    try {
      final db = await DatabaseHelper.instance.database;
      await db.delete('diary_records');
      await db.delete('notes');
      await db.delete('todos');
      await db.delete('folders');
      await db.delete('user_profiles');
      await db.delete('ai_configs');
      await db.delete('shortcut_configs');
      await db.delete('chat_sessions');
      await db.delete('webdav_configs');
      await db.delete('date_color_marks');
      await db.delete('body_states');
      await db.delete('app_configs');
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('数据已清除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据管理'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text('导入与导出', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
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
              children: [
                _buildActionButton(
                  theme,
                  icon: Icons.file_download_outlined,
                  title: '导出 JSON 备份',
                  color: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  onTap: _isExporting ? null : _handleExport,
                  isLoading: _isExporting,
                ),
                const SizedBox(height: 16),
                _buildActionButton(
                  theme,
                  icon: Icons.file_upload_outlined,
                  title: '导入备份数据',
                  color: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  onTap: _isImporting ? null : _handleImport,
                  isLoading: _isImporting,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
          const SizedBox(height: 32),
          _buildActionButton(
            theme,
            icon: Icons.delete_outline,
            title: '清空所有本地数据',
            color: Colors.red,
            backgroundColor: Colors.red.withValues(alpha: 0.1),
            onTap: _handleClearData,
          ),
          const SizedBox(height: 16),
          _buildActionButton(
            theme,
            icon: Icons.terminal,
            title: '查看运行日志',
            color: theme.colorScheme.onSurfaceVariant,
            backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            onTap: _showLogViewer,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required Color color,
    required Color backgroundColor,
    required VoidCallback? onTap,
    bool isLoading = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (isLoading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(Icons.chevron_right, color: color, size: 20),
          ],
        ),
      ),
    );
  }
}

class _LogViewerPage extends StatefulWidget {
  const _LogViewerPage();

  @override
  State<_LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<_LogViewerPage> {
  final LoggerService _logger = LoggerService.instance;
  LogCategory? _selectedCategory;
  LogLevel? _selectedLevel;
  
  @override
  Widget build(BuildContext context) {
    var entries = _logger.entries;
    
    if (_selectedCategory != null) {
      entries = entries.where((e) => e.category == _selectedCategory).toList();
    }
    
    if (_selectedLevel != null) {
      entries = entries.where((e) => e.level == _selectedLevel).toList();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            onSelected: (value) {
              setState(() {
                if (value == 'all') {
                  _selectedCategory = null;
                  _selectedLevel = null;
                } else if (value.startsWith('cat_')) {
                  _selectedCategory = LogCategory.values[int.parse(value.substring(4))];
                } else if (value.startsWith('lvl_')) {
                  _selectedLevel = LogLevel.values[int.parse(value.substring(4))];
                }
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'all', child: Text('显示全部')),
              const PopupMenuDivider(),
              const PopupMenuHeader(child: Text('按分类')),
              ...LogCategory.values.map((cat) => PopupMenuItem(
                value: 'cat_${cat.index}',
                child: Row(
                  children: [
                    Icon(_getCategoryIcon(cat), size: 18),
                    const SizedBox(width: 8),
                    Text(_getCategoryName(cat)),
                    const Spacer(),
                    if (_selectedCategory == cat)
                      const Icon(Icons.check, size: 18, color: Colors.blue),
                  ],
                ),
              )),
              const PopupMenuDivider(),
              const PopupMenuHeader(child: Text('按级别')),
              ...LogLevel.values.map((level) => PopupMenuItem(
                value: 'lvl_${level.index}',
                child: Row(
                  children: [
                    Container(width: 12, height: 12, decoration: BoxDecoration(
                      color: _getLevelColor(level),
                      shape: BoxShape.circle,
                    )),
                    const SizedBox(width: 8),
                    Text(_getLevelName(level)),
                    const Spacer(),
                    if (_selectedLevel == level)
                      const Icon(Icons.check, size: 18, color: Colors.blue),
                  ],
                ),
              )),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final text = _logger.getAllLogsAsString(
                filterCategory: _selectedCategory,
                filterLevel: _selectedLevel,
              );
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('日志已复制到剪贴板')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await _logger.clearLogs();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_selectedCategory != null || _selectedLevel != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  if (_selectedCategory != null)
                    Chip(
                      label: Text(_getCategoryName(_selectedCategory!)),
                      avatar: Icon(_getCategoryIcon(_selectedCategory!), size: 16),
                      onDeleted: () => setState(() => _selectedCategory = null),
                    ),
                  if (_selectedLevel != null)
                    Chip(
                      label: Text(_getLevelName(_selectedLevel!)),
                      backgroundColor: _getLevelColor(_selectedLevel!).withAlpha(51),
                      onDeleted: () => setState(() => _selectedLevel = null),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      _selectedCategory = null;
                      _selectedLevel = null;
                    }),
                    child: const Text('清除筛选'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('暂无日志'))
                : ListView.builder(
                    itemCount: entries.length,
                    reverse: true,
                    itemBuilder: (context, index) {
                      final entry = entries[entries.length - 1 - index];
                      return _buildLogItem(entry);
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatChip('总计', '${_logger.totalEntries}', Icons.receipt_long),
                _buildStatChip('AI', '${_logger.getLogsByCategory(LogCategory.ai).length}', Icons.smart_toy),
                _buildStatChip('错误', '${_logger.getLogsByLevel(LogLevel.error).length}', Icons.error, Colors.red),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogItem(LogEntry entry) {
    final levelStr = switch (entry.level) {
      LogLevel.info => 'INFO',
      LogLevel.warning => 'WARN',
      LogLevel.error => 'ERROR',
    };
    final levelColor = _getLevelColor(entry.level);
    final categoryStr = _getCategoryName(entry.category);
    
    return InkWell(
      onTap: entry.details != null ? () => _showLogDetails(entry) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_getCategoryIcon(entry.category), size: 16, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '[${_formatTime(entry.timestamp)}] [$categoryStr] ${entry.message}',
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: levelColor,
                    ),
                  ),
                  if (entry.details != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: Text(
                        entry.details!,
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: levelColor.withAlpha(26),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(levelStr, style: TextStyle(fontSize: 10, color: levelColor, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _showLogDetails(LogEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_getCategoryName(entry.category)} - ${_getLevelName(entry.level)}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('时间: ${entry.timestamp.toIso8601String()}'),
              const SizedBox(height: 8),
              Text('消息: ${entry.message}'),
              if (entry.details != null) ...[
                const SizedBox(height: 8),
                const Text('详情:', style: TextStyle(fontWeight: FontWeight.bold)),
                SelectableText(entry.details!, style: const TextStyle(fontSize: 12)),
              ],
              if (entry.stackTrace != null) ...[
                const SizedBox(height: 8),
                const Text('堆栈跟踪:', style: TextStyle(fontWeight: FontWeight.bold)),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    entry.stackTrace.toString(),
                    style: const TextStyle(fontSize: 11, color: Colors.green, fontFamily: 'monospace'),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String count, IconData icon, [Color? color]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? Colors.grey),
        const SizedBox(width: 4),
        Text('$label: $count', style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  IconData _getCategoryIcon(LogCategory cat) {
    return switch (cat) {
      LogCategory.system => Icons.settings,
      LogCategory.ai => Icons.smart_toy,
      LogCategory.database => Icons.storage,
      LogCategory.network => Icons.cloud,
      LogCategory.ui => Icons.touch_app,
      LogCategory.sync => Icons.sync,
      LogCategory.export => Icons.upload,
      LogCategory.import => Icons.download,
      LogCategory.config => Icons.tune,
    };
  }

  String _getCategoryName(LogCategory cat) {
    return switch (cat) {
      LogCategory.system => '系统',
      LogCategory.ai => 'AI',
      LogCategory.database => '数据库',
      LogCategory.network => '网络',
      LogCategory.ui => '界面',
      LogCategory.sync => '同步',
      LogCategory.export => '导出',
      LogCategory.import => '导入',
      LogCategory.config => '配置',
    };
  }

  Color _getLevelColor(LogLevel level) {
    return switch (level) {
      LogLevel.info => Colors.grey,
      LogLevel.warning => Colors.orange,
      LogLevel.error => Colors.red,
    };
  }

  String _getLevelName(LogLevel level) {
    return switch (level) {
      LogLevel.info => '信息',
      LogLevel.warning => '警告',
      LogLevel.error => '错误',
    };
  }
}

class PopupMenuHeader<T> extends PopupMenuItem<T> {
  const PopupMenuHeader({required super.child, super.key});
  
  @override
  bool represents(T? value) => false;
  
  @override
  bool get enabled => false;
}

