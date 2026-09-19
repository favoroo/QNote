import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/storage/screen_usage_daily_repository.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';

/// 屏幕时长 tab 的时间范围（与统计页顶部的 TimeRangeSelector 共用一个枚举）
final screenUsageTimeRangeProvider = StateProvider<TimeRangeType>(
  (ref) => TimeRangeType.week,
);

/// 区间起止与「上期同期」边界
class ScreenRangeBounds {
  /// 区间首日 00:00
  final DateTime start;

  /// 区间末日 00:00（自然边界，可能晚于今天）
  final DateTime end;

  /// 实际参与统计的末日：未过完的区间截断到今天
  final DateTime dataEnd;
  final DateTime prevStart;
  final DateTime prevEnd;

  const ScreenRangeBounds({
    required this.start,
    required this.end,
    required this.dataEnd,
    required this.prevStart,
    required this.prevEnd,
  });

  /// 区间内自然日天数（含 dataEnd）
  int get spanDays => dataEnd.difference(start).inDays + 1;

  /// 上期同期天数，与本期对齐
  int get prevSpanDays => prevEnd.difference(prevStart).inDays + 1;
}

/// 解析所选日所属的周/月/年区间，并给出**同期截断**的上期边界。
///
/// 截断是必须的：本月只过了 20 天却和上月整月比，环比永远显示「减少」。
ScreenRangeBounds resolveScreenRange(TimeRangeType range, DateTime anchor) {
  final day = DateTime(anchor.year, anchor.month, anchor.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  final DateTime start;
  final DateTime end;
  switch (range) {
    case TimeRangeType.week:
      start = mondayOf(day);
      end = start.add(const Duration(days: 6));
    case TimeRangeType.month:
      start = DateTime(day.year, day.month);
      end = DateTime(day.year, day.month + 1, 0);
    case TimeRangeType.year:
      start = DateTime(day.year);
      end = DateTime(day.year, 12, 31);
  }

  // 只统计到今天；所选区间整体在未来时不做强截断，交由上层判空
  final dataEnd = end.isAfter(today)
      ? (start.isAfter(today) ? start : today)
      : end;
  final elapsedDays = dataEnd.difference(start).inDays;

  final DateTime prevStart;
  switch (range) {
    case TimeRangeType.week:
      prevStart = start.subtract(const Duration(days: 7));
    case TimeRangeType.month:
      prevStart = DateTime(start.year, start.month - 1);
    case TimeRangeType.year:
      prevStart = DateTime(start.year - 1);
  }
  // 上期同样只取前 elapsedDays+1 天，保证两期天数一致
  final DateTime prevNaturalEnd;
  switch (range) {
    case TimeRangeType.week:
      prevNaturalEnd = prevStart.add(const Duration(days: 6));
    case TimeRangeType.month:
      prevNaturalEnd = DateTime(prevStart.year, prevStart.month + 1, 0);
    case TimeRangeType.year:
      prevNaturalEnd = DateTime(prevStart.year, 12, 31);
  }
  final prevCandidate = prevStart.add(Duration(days: elapsedDays));
  final prevEnd = prevCandidate.isAfter(prevNaturalEnd)
      ? prevNaturalEnd
      : prevCandidate;

  return ScreenRangeBounds(
    start: start,
    end: end,
    dataEnd: dataEnd,
    prevStart: prevStart,
    prevEnd: prevEnd,
  );
}

/// 周一为一周起点
DateTime mondayOf(DateTime d) {
  return DateTime(
    d.year,
    d.month,
    d.day,
  ).subtract(Duration(days: d.weekday - 1));
}

/// 包名末段，作为拿不到应用标签时的兜底显示
String _lastSegment(String packageName) {
  final idx = packageName.lastIndexOf('.');
  return idx >= 0 && idx < packageName.length - 1
      ? packageName.substring(idx + 1)
      : packageName;
}

/// 区间聚合结果
class ScreenUsageAggregate {
  final ScreenRangeBounds bounds;
  final int totalMs;

  /// 区间内有使用记录的天数（日均的分母）
  final int recordedDays;

  /// 区间内自然日天数
  final int spanDays;
  final int avgMs;
  final int previousTotalMs;

  /// 区间内逐日累计后的应用排行
  final List<ScreenAppUsage> topApps;

  /// 上期在文案里的称呼（上周 / 上月 / 去年同期）
  final String previousLabel;

  const ScreenUsageAggregate({
    required this.bounds,
    required this.totalMs,
    required this.recordedDays,
    required this.spanDays,
    required this.avgMs,
    required this.previousTotalMs,
    required this.topApps,
    required this.previousLabel,
  });

  bool get hasData => totalMs > 0;

  String get formattedTotal => formatScreenDuration(totalMs);
  String get formattedAvg => formatScreenDuration(avgMs);
  String get diffText => screenDurationDiffText(
    totalMs,
    previousTotalMs,
    comparedLabel: previousLabel,
  );

  /// 日均分母：按有记录天数，而非自然天数。
  ///
  /// 用自然天数会让「只采集了 3 天却看整月」的用户看到一个荒谬的低值，
  /// 并且把采集缺口伪装成「你用得少」。
  static int computeAvg(int totalMs, int recordedDays) {
    if (recordedDays <= 0) {
      return 0;
    }
    return totalMs ~/ recordedDays;
  }

  /// 把逐日明细合并成区间 Top 榜
  static List<ScreenAppUsage> mergeTopApps(
    Iterable<ScreenUsageDaily> days, {
    int limit = 30,
  }) {
    final merged = <String, int>{};
    final names = <String, String>{};
    for (final day in days) {
      for (final app in day.topApps) {
        merged[app.packageName] = (merged[app.packageName] ?? 0) + app.timeMs;
        if (app.appName.isNotEmpty) {
          names[app.packageName] = app.appName;
        }
      }
    }
    final list = merged.entries
        .map(
          (e) => ScreenAppUsage(
            packageName: e.key,
            appName: names[e.key] ?? _lastSegment(e.key),
            timeMs: e.value,
          ),
        )
        .toList();
    list.sort((a, b) => b.timeMs.compareTo(a.timeMs));
    return list.take(limit).toList();
  }
}

class ScreenUsageRangeArg {
  final TimeRangeType range;
  final DateTime anchor;

  ScreenUsageRangeArg(this.range, DateTime anchor)
    : anchor = DateTime(anchor.year, anchor.month, anchor.day);

  @override
  bool operator ==(Object other) =>
      other is ScreenUsageRangeArg &&
      other.range == range &&
      other.anchor == anchor;

  @override
  int get hashCode => Object.hash(range, anchor);
}

/// 区间聚合：总量 / 日均 / 有记录天数 / 上期同期 / 区间累计 Top 应用
final screenUsageRangeProvider =
    FutureProvider.family<ScreenUsageAggregate, ScreenUsageRangeArg>((
      ref,
      arg,
    ) async {
      final repo = ref.read(screenUsageDailyRepositoryProvider);
      final bounds = resolveScreenRange(arg.range, arg.anchor);

      final days = await repo.getRange(
        ScreenUsageDaily.dateKey(bounds.start),
        ScreenUsageDaily.dateKey(bounds.dataEnd),
      );
      final prevDays = await repo.getRange(
        ScreenUsageDaily.dateKey(bounds.prevStart),
        ScreenUsageDaily.dateKey(bounds.prevEnd),
      );

      final totalMs = days.fold<int>(0, (sum, e) => sum + e.totalTimeMs);
      final recordedDays = days.where((e) => e.totalTimeMs > 0).length;
      final previousTotalMs = prevDays.fold<int>(
        0,
        (sum, e) => sum + e.totalTimeMs,
      );

      return ScreenUsageAggregate(
        bounds: bounds,
        totalMs: totalMs,
        recordedDays: recordedDays,
        spanDays: bounds.spanDays,
        avgMs: ScreenUsageAggregate.computeAvg(totalMs, recordedDays),
        previousTotalMs: previousTotalMs,
        topApps: ScreenUsageAggregate.mergeTopApps(days),
        previousLabel: _previousLabel(arg.range),
      );
    });

String _previousLabel(TimeRangeType range) {
  switch (range) {
    case TimeRangeType.week:
      return '上周';
    case TimeRangeType.month:
      return '上月';
    case TimeRangeType.year:
      return '去年同期';
  }
}

/// 单日详情视图模型
class ScreenUsageDayView {
  final DateTime date;
  final int totalTimeMs;
  final int previousTotalMs;
  final List<AppUsageInfo> apps;

  /// false 表示该日早于最早采集日 —— 「还没开始记录」而不是「没用手机」
  final bool collected;
  final bool isToday;

  const ScreenUsageDayView({
    required this.date,
    required this.totalTimeMs,
    required this.previousTotalMs,
    required this.apps,
    required this.collected,
    required this.isToday,
  });

  bool get hasRecord => totalTimeMs > 0;
  String get formattedTotal => formatScreenDuration(totalTimeMs);
  String get diffText => screenDurationDiffText(totalTimeMs, previousTotalMs);
}

/// 单日详情：今天与系统窗口内的近期日走实时查询（能拿到图标与完整榜单），
/// 更早的日期回落到快照。总时长取两者最大值，与快照的「不倒退」策略保持一致。
final screenUsageDayProvider =
    FutureProvider.family<ScreenUsageDayView, DateTime>((ref, date) async {
      final day = DateTime(date.year, date.month, date.day);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final isToday = day == today;

      final repo = ref.read(screenUsageDailyRepositoryProvider);
      final service = ref.read(screenUsageServiceProvider);

      final key = ScreenUsageDaily.dateKey(day);
      final snapshot = await repo.getByDate(key);
      final earliest = await repo.earliestDate();

      TodayScreenUsage? live;
      if (service.isSupported && !day.isAfter(today)) {
        live = isToday
            ? await service.getTodayUsage(limit: 30)
            : await service.getUsageForDate(day, limit: 30, includeIcons: true);
      }

      final liveTotal = live?.totalTimeMs ?? 0;
      final snapshotTotal = snapshot?.totalTimeMs ?? 0;
      final totalMs = liveTotal > snapshotTotal ? liveTotal : snapshotTotal;

      final useLiveApps =
          live != null && live.appList.isNotEmpty && liveTotal >= snapshotTotal;
      final apps = useLiveApps
          ? live.appList
          : (snapshot?.topApps ?? const [])
                .map(
                  (e) => AppUsageInfo(
                    packageName: e.packageName,
                    appName: e.appName,
                    totalTimeInForegroundMs: e.timeMs,
                    lastTimeUsedMs: 0,
                  ),
                )
                .toList();

      final prevDay = day.subtract(const Duration(days: 1));
      final prevSnapshot = await repo.getByDate(
        ScreenUsageDaily.dateKey(prevDay),
      );
      final livePrev = live?.yesterdayTotalTimeMs ?? 0;
      final prevTotal = livePrev > (prevSnapshot?.totalTimeMs ?? 0)
          ? livePrev
          : (prevSnapshot?.totalTimeMs ?? 0);

      return ScreenUsageDayView(
        date: day,
        totalTimeMs: totalMs,
        previousTotalMs: prevTotal,
        apps: apps,
        // 表里还没有任何数据时一律按「未采集」处理，否则空库+远期日期会被
        // 误报成「当天没有使用记录」，把采集缺口说成用户没用手机
        collected:
            snapshot != null ||
            (earliest != null && !day.isBefore(earliest)),
        isToday: isToday,
      );
    });

/// 趋势图的一根柱子对应的请求参数
class ScreenUsageTrendArg {
  /// null 表示「以所选日为终点的近 N 天」
  final TimeRangeType? range;
  final DateTime anchor;

  ScreenUsageTrendArg(this.range, DateTime anchor)
    : anchor = DateTime(anchor.year, anchor.month, anchor.day);

  @override
  bool operator ==(Object other) =>
      other is ScreenUsageTrendArg &&
      other.range == range &&
      other.anchor == anchor;

  @override
  int get hashCode => Object.hash(range, anchor);
}

/// 趋势图数据
class ScreenUsageTrend {
  final List<ScreenUsageTrendPoint> points;

  /// true 为按月分桶（年视图），false 为按日
  final bool monthly;

  const ScreenUsageTrend({required this.points, required this.monthly});

  bool get isEmpty => points.every((e) => !e.collected);
  double get maxHours =>
      points.fold<double>(0, (m, e) => e.hours > m ? e.hours : m);
}

/// 趋势序列：周→7 日柱、月→当月每日柱、年→12 月柱、单日视图→近 14 日柱。
/// 缺口日标为未采集，由 UI 画成空心柱，与「当天真没用机」区分。
final screenUsageTrendProvider =
    FutureProvider.family<ScreenUsageTrend, ScreenUsageTrendArg>((
      ref,
      arg,
    ) async {
      final repo = ref.read(screenUsageDailyRepositoryProvider);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      if (arg.range == TimeRangeType.year) {
        final yearStart = DateTime(arg.anchor.year);
        final yearEnd = DateTime(arg.anchor.year, 12, 31);
        final rows = await repo.getRange(
          ScreenUsageDaily.dateKey(yearStart),
          ScreenUsageDaily.dateKey(yearEnd),
        );
        final buckets = List<int>.filled(12, 0);
        final touched = List<bool>.filled(12, false);
        for (final row in rows) {
          final d = ScreenUsageDaily.parseDateKey(row.date);
          if (d == null) {
            continue;
          }
          buckets[d.month - 1] += row.totalTimeMs;
          if (row.totalTimeMs > 0) {
            touched[d.month - 1] = true;
          }
        }
        final points = <ScreenUsageTrendPoint>[];
        for (int i = 0; i < 12; i++) {
          points.add(
            ScreenUsageTrendPoint(
              date: DateTime(arg.anchor.year, i + 1),
              totalTimeMs: buckets[i],
              collected: touched[i],
            ),
          );
        }
        return ScreenUsageTrend(points: points, monthly: true);
      }

      final DateTime start;
      final DateTime end;
      if (arg.range == null) {
        end = arg.anchor.isAfter(today) ? today : arg.anchor;
        start = end.subtract(const Duration(days: 13));
      } else {
        final bounds = resolveScreenRange(arg.range!, arg.anchor);
        start = bounds.start;
        end = bounds.dataEnd;
      }

      final rows = await repo.getRange(
        ScreenUsageDaily.dateKey(start),
        ScreenUsageDaily.dateKey(end),
      );
      final byDate = {for (final row in rows) row.date: row};
      final earliest = await repo.earliestDate();

      final points = <ScreenUsageTrendPoint>[];
      for (
        DateTime d = start;
        !d.isAfter(end);
        d = d.add(const Duration(days: 1))
      ) {
        final row = byDate[ScreenUsageDaily.dateKey(d)];
        points.add(
          ScreenUsageTrendPoint(
            date: d,
            totalTimeMs: row?.totalTimeMs ?? 0,
            collected:
                row != null || (earliest != null && !d.isBefore(earliest)),
          ),
        );
      }

      return ScreenUsageTrend(points: points, monthly: false);
    });

/// 最早已采集日期，UI 据此判断「未采集」提示的边界与文案
final screenUsageEarliestDateProvider = FutureProvider<DateTime?>((ref) {
  return ref.read(screenUsageDailyRepositoryProvider).earliestDate();
});
