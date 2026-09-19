import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/storage/screen_usage_daily_repository.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';

/// 屏幕时长固定按周统计（周一~周日），不再暴露周/月/年切换；
/// 这里只复用 TimeRangeSelector 的 TimeRangeType 作为区间口径枚举。

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

/// 区间聚合的入参：以哪天为锚点取它所在的统计区间
class ScreenUsageRangeArg {
  /// 区间口径；屏幕时长目前固定用 week，保留字段以便后续按需扩展
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

/// 周均对比里的一周：总时长与有记录天数，日均由两者算出
class ScreenUsageWeekAvg {
  /// 该周周一
  final DateTime weekStart;
  final int totalMs;

  /// 有使用记录的天数，日均的分母
  final int recordedDays;

  const ScreenUsageWeekAvg({
    required this.weekStart,
    required this.totalMs,
    required this.recordedDays,
  });

  bool get hasData => totalMs > 0;
  int get avgMs => recordedDays > 0 ? totalMs ~/ recordedDays : 0;
  String get formattedAvg => formatScreenDuration(avgMs);
}

/// 周均对比的基准周偏移：0 为所选日所在周，-1 为其上一周，越小越早。
///
/// 只作用于「周均时长对比」区块，不牵动整页口径——整页换周用顶部日期导航更直接。
final screenUsageCompareWeekProvider = StateProvider<int>((ref) => 0);

/// 基准周及其前两周的日均时长：一次查 21 天再按周分桶，避免三次区间查询。
final screenUsageWeekAvgProvider =
    FutureProvider.family<List<ScreenUsageWeekAvg>, DateTime>(
      (ref, baseWeekStart) async {
        final repo = ref.read(screenUsageDailyRepositoryProvider);
        final firstWeekStart = baseWeekStart.subtract(const Duration(days: 14));
        final lastWeekEnd = baseWeekStart.add(const Duration(days: 6));
        final rows = await repo.getRange(
          ScreenUsageDaily.dateKey(firstWeekStart),
          ScreenUsageDaily.dateKey(lastWeekEnd),
        );
        final byDate = {for (final row in rows) row.date: row};

        final weeks = <ScreenUsageWeekAvg>[];
        for (int i = 0; i < 3; i++) {
          final start = baseWeekStart.subtract(Duration(days: 7 * i));
          int totalMs = 0;
          int recordedDays = 0;
          for (int d = 0; d < 7; d++) {
            final row = byDate[
              ScreenUsageDaily.dateKey(start.add(Duration(days: d)))
            ];
            if (row == null) {
              continue;
            }
            totalMs += row.totalTimeMs;
            if (row.totalTimeMs > 0) {
              recordedDays++;
            }
          }
          weeks.add(
            ScreenUsageWeekAvg(
              weekStart: start,
              totalMs: totalMs,
              recordedDays: recordedDays,
            ),
          );
        }
        return weeks;
      },
    );

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

/// 趋势图的请求参数：以哪天为锚点取它所在的整周
class ScreenUsageTrendArg {
  final DateTime anchor;

  ScreenUsageTrendArg(DateTime anchor)
    : anchor = DateTime(anchor.year, anchor.month, anchor.day);

  @override
  bool operator ==(Object other) =>
      other is ScreenUsageTrendArg && other.anchor == anchor;

  @override
  int get hashCode => anchor.hashCode;
}

/// 趋势图数据：所选日所在周的逐日柱
class ScreenUsageTrend {
  final List<ScreenUsageTrendPoint> points;

  const ScreenUsageTrend({required this.points});

  bool get isEmpty => points.every((e) => !e.collected);
  double get maxHours =>
      points.fold<double>(0, (m, e) => e.hours > m ? e.hours : m);
}

/// 所选日所在周（周一~周日，未过完的日子不纳入）的逐日趋势。
/// 缺口日标为未采集，由 UI 画成空柱，与「当天真没用机」区分。
final screenUsageTrendProvider =
    FutureProvider.family<ScreenUsageTrend, ScreenUsageTrendArg>((
      ref,
      arg,
    ) async {
      final repo = ref.read(screenUsageDailyRepositoryProvider);
      final bounds = resolveScreenRange(TimeRangeType.week, arg.anchor);
      final start = bounds.start;
      final end = bounds.dataEnd;

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

      return ScreenUsageTrend(points: points);
    });

/// 最早已采集日期，UI 据此判断「未采集」提示的边界与文案
final screenUsageEarliestDateProvider = FutureProvider<DateTime?>((ref) {
  return ref.read(screenUsageDailyRepositoryProvider).earliestDate();
});

/// 应用图标批量拉取，key 为逗号拼接的包名集合（family 需要可比较的 key）。
///
/// 区间应用榜与历史日明细只有包名，图标要回原生按包名补齐；
/// 字节缓存在 ScreenUsageService 里常驻，同一批包名不会重复走 IPC。
final screenAppIconProvider =
    FutureProvider.family<Map<String, Uint8List>, String>((ref, key) async {
      if (key.isEmpty) {
        return const {};
      }
      return ref.read(screenUsageServiceProvider).getIcons(key.split(','));
    });
