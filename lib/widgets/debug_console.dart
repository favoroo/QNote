import 'package:flutter/material.dart';

enum LogLevel { info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;

  LogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });
}

class DebugConsoleController {
  DebugConsoleController._();
  static final DebugConsoleController instance = DebugConsoleController._();

  final List<LogEntry> _logs = [];
  static const int maxLogs = 500;

  VoidCallback? onLogsChanged;

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void log(String message, [LogLevel level = LogLevel.info]) {
    _logs.add(LogEntry(
      timestamp: DateTime.now(),
      message: message,
      level: level,
    ));
    if (_logs.length > maxLogs) {
      _logs.removeRange(0, _logs.length - maxLogs);
    }
    onLogsChanged?.call();
  }

  void clear() {
    _logs.clear();
    onLogsChanged?.call();
  }

  String copyAll() {
    final buffer = StringBuffer();
    for (final entry in _logs) {
      buffer.writeln(
        '${_formatTimestamp(entry.timestamp)} [${entry.level.name.toUpperCase()}] ${entry.message}',
      );
    }
    return buffer.toString();
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }
}

final _controller = DebugConsoleController.instance;

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
    _controller.onLogsChanged = _onLogsChanged;
  }

  @override
  void dispose() {
    _controller.onLogsChanged = null;
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  List<LogEntry> get _filteredLogs {
    if (_filter == null) return _controller.logs;
    return _controller.logs.where((e) => e.level == _filter).toList();
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return Colors.white;
      case LogLevel.warning:
        return Colors.yellow;
      case LogLevel.error:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;
    return Material(
      color: Colors.black87,
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
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        final entry = logs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '${_controller._formatTimestamp(entry.timestamp)} ${entry.message}',
                            style: TextStyle(
                              color: _levelColor(entry.level),
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
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
              final text = _controller.copyAll();
              if (text.isNotEmpty) {
                // ignore: avoid_print
                debugPrint(text);
              }
            },
            tooltip: '复制全部',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 20),
            onPressed: () => _controller.clear(),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
