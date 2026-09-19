import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/screen_usage_daily_repository.dart';

final screenUsageSnapshotServiceProvider = Provider<ScreenUsageSnapshotService>(
  (ref) {
    return ScreenUsageSnapshotService(ref);
  },
);

/// 每日屏幕时长快照采集器
///
/// 存在的理由：系统 UsageStats 只保留最近约 7 天，不落库就永远做不出「本月统计」
/// 和任意历史日期回看。这里不依赖后台定时器（Android 后台限制严、耗电且无必要），
/// 而是在启动、回前台、进入统计页三个时机各跑一次区间回填。
class ScreenUsageSnapshotService {
  /// 单次回填的天数窗口。系统实际能给的通常少于这个值，多问几天没有副作用。
  static const int backfillDays = 14;

  /// 节流窗口：区间回填只有一次原生调用，30 分钟足够保证「今日」数字不会明显滞后
  static const Duration throttle = Duration(minutes: 30);

  static const String _kLastSnapshotMs = 'screen_usage_last_snapshot_ms';

  final Ref _ref;

  bool _running = false;

  ScreenUsageSnapshotService(this._ref);

  /// 执行一次快照采集（含节流）。[force] 为 true 时忽略节流，用于下拉刷新。
  ///
  /// 返回是否真正写入了数据；不支持的平台、未授权、节流命中均返回 false。
  Future<bool> ensureSnapshot({bool force = false}) async {
    final service = _ref.read(screenUsageServiceProvider);
    if (!service.isSupported) {
      return false;
    }
    if (_running) {
      // 启动与回前台可能同时触发，避免重复跑
      return false;
    }
    _running = true;
    try {
      if (!force && await _throttled()) {
        return false;
      }
      if (!await service.hasPermission()) {
        return false;
      }

      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final start = todayStart.subtract(const Duration(days: backfillDays - 1));

      final daily = await service.getDailyScreenTimeRange(start, now);
      if (daily.isEmpty) {
        return false;
      }

      // 丢弃总时长为 0 的日期：这类日期多半已落在系统窗口之外（查不到 ≠ 没用机），
      // 若照样落库会把 earliestDate 推到一片空行上，UI 就再也分不清「未采集」和「没用机」。
      final usable = daily.where((e) => e.totalTimeMs > 0).toList();
      if (usable.isEmpty) {
        await _recordSnapshotTime();
        return false;
      }

      await _ref
          .read(screenUsageDailyRepositoryProvider)
          .upsertSnapshots(usable);
      await _recordSnapshotTime();
      return true;
    } catch (e, stack) {
      LoggerService.instance.error(
        'ScreenUsageSnapshotService.ensureSnapshot failed: $e',
        stackTrace: stack,
      );
      return false;
    } finally {
      _running = false;
    }
  }

  Future<bool> _throttled() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_kLastSnapshotMs);
    if (last == null) {
      return false;
    }
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(last),
    );
    return elapsed < throttle;
  }

  Future<void> _recordSnapshotTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSnapshotMs, DateTime.now().millisecondsSinceEpoch);
  }
}
