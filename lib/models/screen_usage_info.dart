import 'dart:typed_data';

import 'package:qnote_flutter/models/screen_usage_daily.dart';

/// 单个应用的使用情况信息
class AppUsageInfo {
  final String packageName;
  final String appName;
  final int totalTimeInForegroundMs;
  final int lastTimeUsedMs;
  final Uint8List? iconBytes;

  const AppUsageInfo({
    required this.packageName,
    required this.appName,
    required this.totalTimeInForegroundMs,
    required this.lastTimeUsedMs,
    this.iconBytes,
  });

  /// 前台使用分钟数
  int get minutes => totalTimeInForegroundMs ~/ 60000;

  /// 前台使用小时数
  int get hours => minutes ~/ 60;

  /// 剩余分钟数
  int get remainingMinutes => minutes % 60;

  /// 格式化时长显示（如：1小时52分钟、52分钟）
  String get formattedDuration {
    if (minutes < 1) {
      final seconds = (totalTimeInForegroundMs / 1000).round();
      return '$seconds秒';
    }
    if (hours > 0) {
      return remainingMinutes > 0 ? '$hours小时$remainingMinutes分钟' : '$hours小时';
    }
    return '$minutes分钟';
  }

  factory AppUsageInfo.fromMap(Map<dynamic, dynamic> map) {
    return AppUsageInfo(
      packageName: map['packageName'] as String? ?? '',
      appName: map['appName'] as String? ?? '',
      totalTimeInForegroundMs: (map['totalTimeInForeground'] as num?)?.toInt() ?? 0,
      lastTimeUsedMs: (map['lastTimeUsed'] as num?)?.toInt() ?? 0,
      iconBytes: map['icon'] as Uint8List?,
    );
  }
}

/// 每日屏幕使用时间（供周趋势柱状图展示）
class DailyScreenTime {
  final DateTime date;
  final int totalTimeMs;
  final int dayOfWeek; // 1(周日) ~ 7(周六) 或依系统返回
  final bool isToday;

  const DailyScreenTime({
    required this.date,
    required this.totalTimeMs,
    required this.dayOfWeek,
    required this.isToday,
  });

  int get minutes => totalTimeMs ~/ 60000;
  double get hours => totalTimeMs / 3600000.0;

  /// 星期文本（周一、周二...今日）
  String get dayLabel {
    if (isToday) return '今日';
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final idx = date.weekday - 1;
    if (idx >= 0 && idx < weekdays.length) {
      return weekdays[idx];
    }
    return '周${date.weekday}';
  }

  factory DailyScreenTime.fromMap(Map<dynamic, dynamic> map) {
    final dateMillis = (map['date'] as num?)?.toInt() ?? 0;
    return DailyScreenTime(
      date: DateTime.fromMillisecondsSinceEpoch(dateMillis),
      totalTimeMs: (map['totalTime'] as num?)?.toInt() ?? 0,
      dayOfWeek: (map['dayOfWeek'] as num?)?.toInt() ?? 1,
      isToday: map['isToday'] as bool? ?? false,
    );
  }
}

/// 当日屏幕综合统计
class TodayScreenUsage {
  final int totalTimeMs;
  final int yesterdayTotalTimeMs;
  final List<AppUsageInfo> appList;

  const TodayScreenUsage({
    required this.totalTimeMs,
    required this.yesterdayTotalTimeMs,
    required this.appList,
  });

  int get totalMinutes => totalTimeMs ~/ 60000;
  int get hours => totalMinutes ~/ 60;
  int get remainingMinutes => totalMinutes % 60;

  /// 格式化总时长（如：4小时54分钟）
  String get formattedTotalTime {
    if (totalMinutes < 1) {
      final seconds = (totalTimeMs / 1000).round();
      return '$seconds秒';
    }
    if (hours > 0) {
      return remainingMinutes > 0 ? '$hours小时$remainingMinutes分钟' : '$hours小时';
    }
    return '$totalMinutes分钟';
  }

  /// 与昨天对比差值（毫秒）
  int get diffWithYesterdayMs => totalTimeMs - yesterdayTotalTimeMs;

  /// 较昨日文案（如：较昨日增加29分钟 / 较昨日减少15分钟 / 与昨日基本持平）
  String get diffDescription => screenDurationDiffText(totalTimeMs, yesterdayTotalTimeMs);

  factory TodayScreenUsage.fromMap(Map<dynamic, dynamic> map) {
    final rawApps = map['appList'] as List<dynamic>? ?? [];
    final apps = rawApps.map((e) => AppUsageInfo.fromMap(e as Map<dynamic, dynamic>)).toList();

    return TodayScreenUsage(
      totalTimeMs: (map['totalTime'] as num?)?.toInt() ?? 0,
      yesterdayTotalTimeMs: (map['yesterdayTotalTimeMs'] as num?)?.toInt() ?? 0,
      appList: apps,
    );
  }
}
