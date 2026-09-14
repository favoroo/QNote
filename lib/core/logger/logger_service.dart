import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LogLevel { info, warning, error }

enum LogCategory {
  system,
  ai,
  database,
  network,
  ui,
  sync,
  export,
  import,
  config,
}

class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;

  LogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
  });

  Map<String, dynamic> toMap() => {
    'timestamp': timestamp.toIso8601String(),
    'message': message,
    'level': level.index,
  };

  factory LogEntry.fromMap(Map<String, dynamic> map) => LogEntry(
    timestamp: DateTime.parse(map['timestamp'] as String),
    message: map['message'] as String,
    level: LogLevel.values[map['level'] as int? ?? 0],
  );
}

class LoggerService extends ChangeNotifier {
  static final LoggerService _instance = LoggerService._();
  static LoggerService get instance => _instance;
  LoggerService._();

  static const _maxEntries = 35;
  static const _storageKey = 'qnote_logs';

  final List<LogEntry> _entries = [];
  List<LogEntry> get entries => List.unmodifiable(_entries);

  Timer? _debounceTimer;
  int _pendingPersistCount = 0;

  final _entriesController = StreamController<List<LogEntry>>.broadcast();
  Stream<List<LogEntry>> get entriesStream => _entriesController.stream;

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    await loadLogs();
    _setupGlobalInterceptors();
    info('日志系统初始化完成', category: LogCategory.system);
  }

  void _setupGlobalInterceptors() {
    final logger = this;

    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        final filteredMessage = _filterSensitiveData(message);
        final lines = filteredMessage.split('\n');
        for (final line in lines) {
          if (line.trim().isNotEmpty) {
            _addEntry(
              LogEntry(
                timestamp: DateTime.now(),
                message: line,
                level: LogLevel.info,
              ),
            );
          }
        }
      }
      debugPrintThrottled(message, wrapWidth: wrapWidth);
    };

    FlutterError.onError = (FlutterErrorDetails details) {
      final errorMsg = 'Flutter异常: ${details.exceptionAsString()}';
      logger.error(
        errorMsg,
        category: LogCategory.ui,
        stackTrace: details.stack,
        details: details.summary.toString(),
      );
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      final errorMsg = '未捕获的异步错误: $error';
      logger.error(errorMsg, category: LogCategory.system, stackTrace: stack);
      return true;
    };
  }

  String _filterSensitiveData(String message) {
    if (message.length < 500) return message;

    String result = message;

    result = result.replaceAllMapped(
      RegExp(r'data:image/[^;]+;base64,[A-Za-z0-9+/=]{200,}'),
      (match) => 'data:image/*;base64;<IMAGE_DATA>',
    );

    result = result.replaceAllMapped(
      RegExp(r'"/[A-Za-z0-9+/=]{1000,}"'),
      (match) => '"<BASE64_IMAGE_STRING>"',
    );

    result = result.replaceAllMapped(
      RegExp(r'(?:^|\n)([A-Za-z0-9+/=]{3000,})(?:\n|$)'),
      (match) => '\n<LONG_BASE64_DATA_OMITTED>\n',
    );

    return result;
  }

  void info(
    String message, {
    LogCategory category = LogCategory.system,
    String? details,
  }) {
    _log(message, LogLevel.info, category: category, details: details);
  }

  void warning(
    String message, {
    LogCategory category = LogCategory.system,
    String? details,
  }) {
    _log(message, LogLevel.warning, category: category, details: details);
  }

  void error(
    String message, {
    LogCategory category = LogCategory.system,
    String? details,
    StackTrace? stackTrace,
  }) {
    _log(
      message,
      LogLevel.error,
      category: category,
      details: details,
      stackTrace: stackTrace,
    );
  }

  void logAI(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.ai, details: details);
  }

  void logDatabase(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.database, details: details);
  }

  void logNetwork(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.network, details: details);
  }

  void logSync(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.sync, details: details);
  }

  void logUI(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.ui, details: details);
  }

  void logExport(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.export, details: details);
  }

  void logImport(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.import, details: details);
  }

  void logConfig(
    String message, {
    LogLevel level = LogLevel.info,
    String? details,
  }) {
    _log(message, level, category: LogCategory.config, details: details);
  }

  void _log(
    String message,
    LogLevel level, {
    required LogCategory category,
    String? details,
    StackTrace? stackTrace,
  }) {
    final categoryName = category.name.toUpperCase();
    final buffer = StringBuffer();
    buffer.write('[$categoryName] $message');
    if (details != null && details.isNotEmpty) {
      buffer.write('\n详情: $details');
    }
    if (stackTrace != null) {
      buffer.write('\n堆栈:\n$stackTrace');
    }
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: buffer.toString(),
      level: level,
    );
    _addEntry(entry);
  }

  void _addEntry(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    // P1-10: entriesStream 无订阅方时 List.from 复制是无效开销；改传引用
    _entriesController.add(_entries);
    notifyListeners();
    
    _pendingPersistCount++;
    if (_pendingPersistCount >= 10) {
      _persistLogsImmediate();
    } else {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(seconds: 5), () {
        _persistLogsImmediate();
      });
    }
  }

  Future<void> _persistLogsImmediate() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingPersistCount = 0;
    await _persistLogs();
  }

  Future<void> loadLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null) {
        final List<dynamic> list = jsonDecode(jsonStr);
        _entries.clear();
        _entries.addAll(
          list.map((e) => LogEntry.fromMap(e as Map<String, dynamic>)),
        );
        if (_entries.length > _maxEntries) {
          _entries.removeRange(0, _entries.length - _maxEntries);
        }
        _entriesController.add(_entries);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('加载日志失败: $e');
    }
  }

  Future<void> _persistLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_entries.map((e) => e.toMap()).toList());
      await prefs.setString(_storageKey, jsonStr);
    } catch (e) {
      debugPrintThrottled('持久化日志失败: $e');
    }
  }

  Future<void> clearLogs() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingPersistCount = 0;
    _entries.clear();
    _entriesController.add(_entries);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    info('日志已清除', category: LogCategory.system);
  }

  String getAllLogsAsString({
    LogCategory? filterCategory,
    LogLevel? filterLevel,
  }) {
    final buffer = StringBuffer();
    var filteredEntries = _entries;

    if (filterCategory != null) {
      final prefix = '[${filterCategory.name.toUpperCase()}]';
      filteredEntries = filteredEntries
          .where((e) => e.message.startsWith(prefix))
          .toList();
    }

    if (filterLevel != null) {
      filteredEntries = filteredEntries
          .where((e) => e.level == filterLevel)
          .toList();
    }

    for (final entry in filteredEntries.reversed) {
      final levelStr = entry.level.name.toUpperCase();
      buffer.write(
        '[${_formatTimestamp(entry.timestamp)}] [$levelStr] ${entry.message}',
      );
      buffer.writeln();
    }
    return buffer.toString();
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  List<LogEntry> getLogsByCategory(LogCategory category) {
    final prefix = '[${category.name.toUpperCase()}]';
    return _entries.where((e) => e.message.startsWith(prefix)).toList();
  }

  List<LogEntry> getLogsByLevel(LogLevel level) {
    return _entries.where((e) => e.level == level).toList();
  }

  int get totalEntries => _entries.length;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _entriesController.close();
    super.dispose();
  }
}
