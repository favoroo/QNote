import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';

OverlayEntry? _debugOverlayEntry;

void showDebugConsole(BuildContext context) {
  if (_debugOverlayEntry != null) return;

  _debugOverlayEntry = OverlayEntry(
    builder: (context) => const _DebugConsoleOverlay(),
  );
  Overlay.of(context).insert(_debugOverlayEntry!);
}

void hideDebugConsole() {
  _debugOverlayEntry?.remove();
  _debugOverlayEntry = null;
}

class _DebugConsoleOverlay extends StatefulWidget {
  const _DebugConsoleOverlay();

  @override
  State<_DebugConsoleOverlay> createState() => _DebugConsoleOverlayState();
}

class _DebugConsoleOverlayState extends State<_DebugConsoleOverlay> {
  LogLevel? _filter;
  final _scrollController = ScrollController();
  bool _isSelectMode = false;
  final Set<LogEntry> _selectedLogs = {};
  String? _toastMessage;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    LoggerService.instance.addListener(_onLogsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    LoggerService.instance.removeListener(_onLogsChanged);
    _scrollController.dispose();
    _toastTimer?.cancel();
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
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() {
      _toastMessage = message;
    });
    _toastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() {
          _toastMessage = null;
        });
      }
    });
  }

  List<LogEntry> get _filteredLogs {
    final logs = LoggerService.instance.entries;
    if (_filter == null) return logs;
    return logs.where((e) => e.level == _filter).toList();
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return Colors.white70;
      case LogLevel.warning:
        return Colors.orangeAccent;
      case LogLevel.error:
        return Colors.redAccent;
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;
    return Material(
      color: const Color(0xFF0F0F11),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildTopBar(logs),
                _buildFilterBar(),
                Expanded(
                  child: logs.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无日志',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : SelectionArea(
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            itemCount: logs.length,
                            itemBuilder: (context, index) {
                              final entry = logs[index];
                              return _buildLogItem(entry);
                            },
                          ),
                        ),
                ),
              ],
            ),
            if (_toastMessage != null)
              Positioned(
                bottom: 50,
                left: 20,
                right: 20,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xE61E1E24),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12, width: 0.8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        _toastMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(List<LogEntry> logs) {
    if (_isSelectMode) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: const Color(0xFF16161A),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white70, size: 20),
              onPressed: () {
                setState(() {
                  _isSelectMode = false;
                  _selectedLogs.clear();
                });
              },
              tooltip: '取消选择',
            ),
            const SizedBox(width: 8),
            Text(
              '已选择 ${_selectedLogs.length} 项',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.select_all, color: Colors.white70, size: 20),
              onPressed: () {
                setState(() {
                  if (_selectedLogs.length == logs.length) {
                    _selectedLogs.clear();
                    _isSelectMode = false;
                  } else {
                    _selectedLogs.addAll(logs);
                  }
                });
              },
              tooltip: '全选',
            ),
            IconButton(
              icon: const Icon(Icons.copy, color: Colors.white70, size: 20),
              onPressed: _selectedLogs.isEmpty
                  ? null
                  : () {
                      final orderedSelection = logs.where((e) => _selectedLogs.contains(e)).toList();
                      final text = orderedSelection
                          .map((e) => '[${_formatTime(e.timestamp)}] [${e.level.name.toUpperCase()}] ${e.message}')
                          .join('\n');
                      Clipboard.setData(ClipboardData(text: text));
                      setState(() {
                        _isSelectMode = false;
                        _selectedLogs.clear();
                      });
                      _showToast('已复制选中的日志');
                    },
              tooltip: '复制选中',
            ),
          ],
        ),
      );
    }

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF16161A),
      child: Row(
        children: [
          const Text(
            'Debug Console',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.white70, size: 20),
            onPressed: () {
              final text = LoggerService.instance.getAllLogsAsString(
                filterLevel: _filter,
              );
              if (text.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: text));
                _showToast('日志已全部复制到剪贴板');
              }
            },
            tooltip: '复制全部',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 20),
            onPressed: () => LoggerService.instance.clearLogs(),
            tooltip: '清除',
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            onPressed: hideDebugConsole,
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildLogItem(LogEntry entry) {
    final levelColor = _levelColor(entry.level);
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
              _showToast('已复制该条日志内容');
            },
      child: Container(
        color: isSelected ? Colors.blue.withValues(alpha: 0.2) : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
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
                '[${_formatTime(entry.timestamp)}] [${entry.level.name.toUpperCase()}] ${entry.message}',
                style: TextStyle(
                  color: levelColor,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF16161A).withValues(alpha: 0.5),
      child: Row(
        children: [
          _filterChip('All', null),
          const SizedBox(width: 8),
          _filterChip('Info', LogLevel.info),
          const SizedBox(width: 8),
          _filterChip('Warning', LogLevel.warning),
          const SizedBox(width: 8),
          _filterChip('Error', LogLevel.error),
        ],
      ),
    );
  }

  Widget _filterChip(String label, LogLevel? level) {
    final selected = _filter == level;
    return GestureDetector(
      onTap: () {
        if (_filter != level) {
          setState(() => _filter = level);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottom();
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.white24 : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.white54 : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white54,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
