import 'dart:convert';

/// 单日快照中某个应用的使用时长（不含图标，图标只在实时查询时按需拉取）
class ScreenAppUsage {
  final String packageName;
  final String appName;
  final int timeMs;

  const ScreenAppUsage({
    required this.packageName,
    required this.appName,
    required this.timeMs,
  });

  int get minutes => timeMs ~/ 60000;

  /// 格式化时长（如：1小时11分钟、42分钟、35秒）
  String get formattedDuration => formatScreenDuration(timeMs);

  factory ScreenAppUsage.fromMap(Map<dynamic, dynamic> map) {
    return ScreenAppUsage(
      packageName: map['pkg'] as String? ?? '',
      appName: map['name'] as String? ?? '',
      timeMs: (map['ms'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'pkg': packageName,
    'name': appName,
    'ms': timeMs,
  };
}

/// 每日屏幕时长快照，对应 screen_usage_daily 表
class ScreenUsageDaily {
  /// 本地自然日，格式 YYYY-MM-DD
  final String date;
  final int totalTimeMs;

  /// 当日使用时长最高的若干应用
  final List<ScreenAppUsage> topApps;

  /// 该日是否已过完并采集完成；未过完的当日值只是进行中的累计
  final bool isComplete;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ScreenUsageDaily({
    required this.date,
    required this.totalTimeMs,
    this.topApps = const [],
    this.isComplete = false,
    this.source = 'usage_stats',
    required this.createdAt,
    required this.updatedAt,
  });

  int get minutes => totalTimeMs ~/ 60000;
  double get hours => totalTimeMs / 3600000.0;

  /// 当日是否有过使用记录
  bool get hasRecord => totalTimeMs > 0;

  String get formattedTotal => formatScreenDuration(totalTimeMs);

  /// 日期字符串（YYYY-MM-DD）
  static String dateKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  /// 解析 [dateKey] 生成的日期串，失败返回 null
  static DateTime? parseDateKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) {
      return null;
    }
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) {
      return null;
    }
    return DateTime(y, m, d);
  }

  Map<String, dynamic> toMap() => {
    'date': date,
    'total_time_ms': totalTimeMs,
    'top_apps_json': jsonEncode(topApps.map((e) => e.toMap()).toList()),
    'is_complete': isComplete ? 1 : 0,
    'source': source,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ScreenUsageDaily.fromMap(Map<String, dynamic> map) {
    return ScreenUsageDaily(
      date: map['date'] as String? ?? '',
      totalTimeMs: (map['total_time_ms'] as num?)?.toInt() ?? 0,
      topApps: _decodeApps(map['top_apps_json'] as String?),
      isComplete: ((map['is_complete'] as num?)?.toInt() ?? 0) != 0,
      source: map['source'] as String? ?? 'usage_stats',
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(map['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static List<ScreenAppUsage> _decodeApps(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => ScreenAppUsage.fromMap(e))
          .toList();
    } catch (_) {
      // 快照明细损坏时降级为空列表，总时长仍可用
      return const [];
    }
  }

  ScreenUsageDaily copyWith({
    String? date,
    int? totalTimeMs,
    List<ScreenAppUsage>? topApps,
    bool? isComplete,
    String? source,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ScreenUsageDaily(
      date: date ?? this.date,
      totalTimeMs: totalTimeMs ?? this.totalTimeMs,
      topApps: topApps ?? this.topApps,
      isComplete: isComplete ?? this.isComplete,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 统一的时长文案格式化（与 AppUsageInfo/TodayScreenUsage 的展示口径保持一致）
String formatScreenDuration(int timeMs) {
  final minutes = timeMs ~/ 60000;
  if (minutes < 1) {
    final seconds = (timeMs / 1000).round();
    return '$seconds秒';
  }
  final hours = minutes ~/ 60;
  final remaining = minutes % 60;
  if (hours > 0) {
    return remaining > 0 ? '$hours小时$remaining分钟' : '$hours小时';
  }
  return '$minutes分钟';
}

/// 与上一周期对比的差值文案；[comparedLabel] 为被比较对象本身（如「昨日」「上周」）
String screenDurationDiffText(
  int currentMs,
  int previousMs, {
  String comparedLabel = '昨日',
}) {
  if (previousMs <= 0) {
    return '暂无$comparedLabel对比数据';
  }
  final diffMins = (currentMs - previousMs).abs() ~/ 60000;
  if (diffMins == 0) {
    return '与$comparedLabel基本持平';
  }
  final diffHours = diffMins ~/ 60;
  final remMins = diffMins % 60;
  final timeStr = diffHours > 0 && remMins > 0
      ? '$diffHours小时$remMins分钟'
      : (diffHours > 0 ? '$diffHours小时' : '$remMins分钟');
  return currentMs > previousMs
      ? '较$comparedLabel增加$timeStr'
      : '较$comparedLabel减少$timeStr';
}

/// 趋势图中的一根柱子
class ScreenUsageTrendPoint {
  final DateTime date;
  final int totalTimeMs;

  /// 该日是否落在快照采集范围内；false 表示「还没开始记录」而非「没用手机」
  final bool collected;

  const ScreenUsageTrendPoint({
    required this.date,
    required this.totalTimeMs,
    required this.collected,
  });

  double get hours => totalTimeMs / 3600000.0;

  bool get hasRecord => totalTimeMs > 0;
}
