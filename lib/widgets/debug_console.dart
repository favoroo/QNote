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

  @override
  void initState() {
    super.initState();
    LoggerService.instance.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    LoggerService.instance.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (mounted) setState(() {});
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
        child: Column(
          children: [
            _buildTopBar(),
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
                          final entry = logs[logs.length - 1 - index];
                          return InkWell(
                            onDoubleTap: () {
                              Clipboard.setData(ClipboardData(text: entry.message));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制该条日志内容'),
                                  duration: Duration(milliseconds: 800),
                                ),
                              );
                            },
                            onLongPress: () {
                              Clipboard.setData(ClipboardData(text: entry.message));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制该条日志内容'),
                                  duration: Duration(milliseconds: 800),
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                '[${_formatTime(entry.timestamp)}] [${entry.level.name.toUpperCase()}] ${entry.message}',
                                style: TextStyle(
                                  color: _levelColor(entry.level),
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('日志已全部复制到剪贴板')),
                );
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
      onTap: () => setState(() => _filter = level),
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
