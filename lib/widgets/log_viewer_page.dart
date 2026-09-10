import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 运行日志查看页
///
/// 以全屏对话框形式打开，支持按级别筛选、全选复制、双击复制单条。
/// 原为数据管理页的私有组件，随「数据与同步」合并重构后独立成文件，便于维护诊断分区复用。
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => LogViewerPageState();
}

class LogViewerPageState extends State<LogViewerPage> {
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
                    ...LogLevel.values.map(
                      (level) => PopupMenuItem(
                        value: 'lvl_${level.index}',
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: _getLevelColor(level),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(_getLevelName(level)),
                            const Spacer(),
                            if (_selectedLevel == level) const Icon(Icons.check, size: 18, color: Colors.blue),
                          ],
                        ),
                      ),
                    ),
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
