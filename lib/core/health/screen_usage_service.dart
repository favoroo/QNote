import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';

final screenUsageServiceProvider = Provider<ScreenUsageService>((ref) {
  return ScreenUsageService();
});

class ScreenUsageService {
  static const MethodChannel _channel = MethodChannel('com.appone.qnote_flutter/usage_stats');

  /// 当前平台是否支持应用使用情况查询（目前支持 Android）
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 检查是否已获得「有权查看使用情况的应用」权限
  Future<bool> hasPermission() async {
    if (!isSupported) return false;
    try {
      final res = await _channel.invokeMethod<bool>('hasPermission');
      return res ?? false;
    } catch (e, stack) {
      LoggerService.instance.error('ScreenUsageService.hasPermission failed: $e', stackTrace: stack);
      return false;
    }
  }

  /// 打开系统设置中的权限授予页面
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    try {
      final res = await _channel.invokeMethod<bool>('requestPermission');
      return res ?? false;
    } catch (e, stack) {
      LoggerService.instance.error('ScreenUsageService.requestPermission failed: $e', stackTrace: stack);
      return false;
    }
  }

  /// 获取今日屏幕总时长与各应用使用情况
  Future<TodayScreenUsage?> getTodayUsage({int limit = 30}) async {
    if (!isSupported) return null;
    try {
      final res = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getTodayUsage',
        {'limit': limit},
      );
      if (res == null) return null;
      return TodayScreenUsage.fromMap(res);
    } catch (e, stack) {
      LoggerService.instance.error('ScreenUsageService.getTodayUsage failed: $e', stackTrace: stack);
      return null;
    }
  }

  /// 获取指定日期的屏幕总时长与各应用使用情况
  Future<TodayScreenUsage?> getUsageForDate(
    DateTime date, {
    int limit = 10,
    bool includeIcons = false,
  }) async {
    if (!isSupported) return null;
    try {
      final res = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getUsageForDate',
        {
          'dateMillis': date.millisecondsSinceEpoch,
          'limit': limit,
          'includeIcons': includeIcons,
        },
      );
      if (res == null) return null;
      return TodayScreenUsage.fromMap(res);
    } catch (e, stack) {
      LoggerService.instance.error('ScreenUsageService.getUsageForDate failed: $e', stackTrace: stack);
      return null;
    }
  }

  /// 包名 → 图标 PNG 字节 的进程内缓存；取不到（未安装等）记 null，避免反复重试
  final Map<String, Uint8List?> _iconCache = {};

  /// 已缓存的图标，命中可同步返回，列表复用时不必再等 IPC
  Uint8List? peekIcon(String packageName) => _iconCache[packageName];

  /// 按包名批量获取应用图标。
  ///
  /// 区间应用榜与历史日明细来自逐日快照，快照只存包名/名称/时长，图标要回原生补齐；
  /// 已缓存的包名直接跳过，未安装或取图失败的包名不会出现在返回值里。
  Future<Map<String, Uint8List>> getIcons(List<String> packageNames) async {
    if (!isSupported || packageNames.isEmpty) return const {};

    final pending = <String>{
      for (final pkg in packageNames)
        if (pkg.isNotEmpty && !_iconCache.containsKey(pkg)) pkg,
    }.toList();

    if (pending.isNotEmpty) {
      try {
        final res = await _channel.invokeMapMethod<dynamic, dynamic>(
          'getAppIcons',
          {'packageNames': pending},
        );
        final fetched = <String, Uint8List>{};
        res?.forEach((key, value) {
          if (key is String && value is Uint8List && value.isNotEmpty) {
            fetched[key] = value;
          }
        });
        for (final pkg in pending) {
          _iconCache[pkg] = fetched[pkg];
        }
      } catch (e, stack) {
        // 取图失败只影响图标显示，时长与榜单照常；不写缓存，下次进页面还会再试
        LoggerService.instance.error('ScreenUsageService.getIcons failed: $e', stackTrace: stack);
      }
    }

    final icons = <String, Uint8List>{};
    for (final pkg in packageNames) {
      final bytes = _iconCache[pkg];
      if (pkg.isNotEmpty && bytes != null) {
        icons[pkg] = bytes;
      }
    }
    return icons;
  }

  /// 获取最近 7 天的每日屏幕使用总时长
  Future<List<DailyScreenTime>> getWeeklyScreenTime() async {
    if (!isSupported) return [];
    try {
      final res = await _channel.invokeListMethod<dynamic>('getWeeklyScreenTime');
      if (res == null) return [];
      return res
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => DailyScreenTime.fromMap(m))
          .toList();
    } catch (e, stack) {
      LoggerService.instance.error('ScreenUsageService.getWeeklyScreenTime failed: $e', stackTrace: stack);
      return [];
    }
  }

  /// 获取区间内逐日的屏幕总时长与各应用明细（单次原生调用，供每日快照回填）
  ///
  /// 注意：系统 UsageStats 通常只保留最近约 7 天，超出窗口的日期会返回 0，
  /// 调用方不应把 0 当作「当天没用手机」。
  Future<List<ScreenUsageDaily>> getDailyScreenTimeRange(
    DateTime start,
    DateTime end, {
    int appLimitPerDay = 20,
  }) async {
    if (!isSupported) return [];
    try {
      final res = await _channel.invokeListMethod<dynamic>(
        'getDailyScreenTimeRange',
        {
          'startMillis': start.millisecondsSinceEpoch,
          'endMillis': end.millisecondsSinceEpoch,
          'appLimitPerDay': appLimitPerDay,
        },
      );
      if (res == null) return [];
      return res.whereType<Map<dynamic, dynamic>>().map(_parseDailyRange).toList();
    } catch (e, stack) {
      LoggerService.instance.error('ScreenUsageService.getDailyScreenTimeRange failed: $e', stackTrace: stack);
      return [];
    }
  }

  static ScreenUsageDaily _parseDailyRange(Map<dynamic, dynamic> map) {
    final dateMillis = (map['date'] as num?)?.toInt() ?? 0;
    final date = DateTime.fromMillisecondsSinceEpoch(dateMillis);
    final isToday = map['isToday'] as bool? ?? false;
    final rawApps = map['topApps'] as List<dynamic>? ?? [];
    final now = DateTime.now();
    return ScreenUsageDaily(
      date: ScreenUsageDaily.dateKey(date),
      totalTimeMs: (map['totalTime'] as num?)?.toInt() ?? 0,
      topApps: rawApps
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => ScreenAppUsage.fromMap(e))
          .toList(),
      // 今日尚未过完，标记为未完成，避免被当成整日数据参与环比
      isComplete: !isToday,
      createdAt: now,
      updatedAt: now,
    );
  }
}
