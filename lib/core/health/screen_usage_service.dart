import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
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
}
