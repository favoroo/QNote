import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
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
    final result = await FilePicker.pickFiles(
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
        Toast.success(context, '已清除');
      }
    } catch (e) {
      if (mounted) {
        Toast.error(context, '清除失败');
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
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.08),
                  onTap: _isExporting ? null : _handleExport,
                  isLoading: _isExporting,
                ),
                const SizedBox(height: 16),
                _buildActionButton(
                  theme,
                  icon: Icons.file_upload_outlined,
                  title: '导入备份数据',
                  color: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.08),
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
  final _scrollController = ScrollController();
  LogLevel? _selectedLevel;
  bool _isSelectMode = false;
  final Set<LogEntry> _selectedLogs = {};

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onLogsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _logger.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (mounted) {
      setState(() {});
      if (!_isSelectMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    var entries = _logger.entries;
    
    if (_selectedLevel != null) {
      entries = entries.where((e) => e.level == _selectedLevel).toList();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F11),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16161A),
        title: Text(
          _isSelectMode ? '已选择 ${_selectedLogs.length} 项' : '运行日志',
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: _isSelectMode
            ? IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () {
                  setState(() {
                    _isSelectMode = false;
                    _selectedLogs.clear();
                  });
                },
              )
            : null,
        actions: _isSelectMode
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all, color: Colors.white70),
                  onPressed: () {
                    setState(() {
                      if (_selectedLogs.length == entries.length) {
                        _selectedLogs.clear();
                        _isSelectMode = false;
                      } else {
                        _selectedLogs.addAll(entries);
                      }
                    });
                  },
                  tooltip: '全选',
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.white70),
                  onPressed: _selectedLogs.isEmpty
                      ? null
                      : () {
                          final orderedSelection = entries
                              .where((e) => _selectedLogs.contains(e))
                              .toList();
                          final text = orderedSelection
                              .map((e) => '[${_formatTime(e.timestamp)}] [${e.level.name.toUpperCase()}] ${e.message}')
                              .join('\n');
                          Clipboard.setData(ClipboardData(text: text));
                          setState(() {
                            _isSelectMode = false;
                            _selectedLogs.clear();
                          });
                          Toast.success(context, '已复制选中的日志');
                        },
                  tooltip: '复制选中',
                ),
              ]
            : [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.filter_list, color: Colors.white70),
                  onSelected: (value) {
                    setState(() {
                      if (value == 'all') {
                        _selectedLevel = null;
                      } else if (value.startsWith('lvl_')) {
                        _selectedLevel = LogLevel.values[int.parse(value.substring(4))];
                      }
                    });
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'all', child: Text('显示全部')),
                    const PopupMenuDivider(),
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
                  icon: const Icon(Icons.copy, color: Colors.white70),
                  onPressed: () {
                    final text = _logger.getAllLogsAsString(
                      filterLevel: _selectedLevel,
                    );
                    Clipboard.setData(ClipboardData(text: text));
                    Toast.success(context, '日志已复制到剪贴板');
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.white70),
                  onPressed: () async {
                    await _logger.clearLogs();
                    if (mounted) setState(() {});
                  },
                ),
              ],
      ),
      body: Column(
        children: [
          if (_selectedLevel != null && !_isSelectMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF16161A),
              child: Row(
                children: [
                  Chip(
                    label: Text(_getLevelName(_selectedLevel!)),
                    backgroundColor: _getLevelColor(_selectedLevel!).withValues(alpha: 0.2),
                    onDeleted: () => setState(() => _selectedLevel = null),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      _selectedLevel = null;
                    }),
                    child: const Text('清除筛选'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('暂无日志', style: TextStyle(color: Colors.white54)))
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scrollController,
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return _buildLogItem(entry);
                      },
                    ),
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFF16161A),
              border: Border(top: BorderSide(color: Colors.white12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatChip('总计', '${_logger.totalEntries}', Icons.receipt_long),
                _buildStatChip('错误', '${_logger.getLogsByLevel(LogLevel.error).length}', Icons.error, Colors.redAccent),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogItem(LogEntry entry) {
    final levelStr = entry.level.name.toUpperCase();
    final levelColor = _getLevelColor(entry.level);
    final formattedTime = _formatTime(entry.timestamp);
    final isSelected = _selectedLogs.contains(entry);
    
    return InkWell(
      onTap: () {
        if (_isSelectMode) {
          setState(() {
            if (isSelected) {
              _selectedLogs.remove(entry);
              if (_selectedLogs.isEmpty) {
                _isSelectMode = false;
              }
            } else {
              _selectedLogs.add(entry);
            }
          });
        }
      },
      onLongPress: () {
        if (!_isSelectMode) {
          setState(() {
            _isSelectMode = true;
            _selectedLogs.add(entry);
          });
        }
      },
      onDoubleTap: _isSelectMode
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: entry.message));
              Toast.success(context, '已复制该条日志内容');
            },
      child: Container(
        color: isSelected ? Colors.blue.withValues(alpha: 0.2) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isSelectMode) ...[
              Icon(
                isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: isSelected ? Colors.blue : Colors.white54,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                '[$formattedTime] [$levelStr] ${entry.message}',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: levelColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(String label, String count, IconData icon, [Color? color]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? Colors.white70),
        const SizedBox(width: 4),
        Text('$label: $count', style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  Color _getLevelColor(LogLevel level) {
    return switch (level) {
      LogLevel.info => Colors.white70,
      LogLevel.warning => Colors.orangeAccent,
      LogLevel.error => Colors.redAccent,
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

