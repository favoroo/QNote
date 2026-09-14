import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';

/// 统计查询参数，用作 statsProvider 的 family key
/// 重写 == / hashCode 确保 (start, end, tab) 任意一个变化都会重算
class StatsQuery {
  final DateTime start;
  final DateTime end;
  final StatTab tab;

  const StatsQuery({
    required this.start,
    required this.end,
    required this.tab,
  });

  @override
  bool operator ==(Object other) =>
      other is StatsQuery &&
      start == other.start &&
      end == other.end &&
      tab == other.tab;

  @override
  int get hashCode => Object.hash(start, end, tab);
}

// ============ compute 顶层函数（isolate 不能传闭包，必须顶层或静态） ============
// 通过 Map 传参，避免 isolate 边界对闭包的限制

SleepStatistics _calcSleepStats(Map<String, dynamic> args) {
  return calculateSleepStats(
    args['records'] as List<DiaryRecord>,
    args['start'] as DateTime,
    args['end'] as DateTime,
  );
}

DietStatistics _calcDietStats(Map<String, dynamic> args) {
  return calculateDietStats(
    args['records'] as List<DiaryRecord>,
    args['start'] as DateTime,
    args['end'] as DateTime,
  );
}

FinanceStatistics _calcFinanceStats(Map<String, dynamic> args) {
  return calculateFinanceStats(
    args['records'] as List<DiaryRecord>,
    args['start'] as DateTime,
    args['end'] as DateTime,
  );
}

MoodStatistics _calcMoodStats(Map<String, dynamic> args) {
  return calculateMoodStats(
    args['records'] as List<DiaryRecord>,
    args['start'] as DateTime,
    args['end'] as DateTime,
  );
}

ActivityStatistics _calcActivityStats(Map<String, dynamic> args) {
  return calculateActivityStats(
    args['records'] as List<DiaryRecord>,
    args['start'] as DateTime,
    args['end'] as DateTime,
  );
}

/// 统计结果 Provider：依赖 (start, end, tab)
///
/// - 自动响应 [diaryListByDateRangeProvider]：日记增删改后重算
/// - 走 [compute] 在 isolate 中跑统计，不阻塞 UI 线程
/// - 解决 P0-2（isolate 化）+ P0-9（按时间范围拉取）+ P1-26（避免 stats 函数内部冗余过滤）
final statsProvider = FutureProvider.family<Object, StatsQuery>((
  ref,
  query,
) async {
  // watch future：records 还在加载时本 provider 会自动 awaiting
  final records = await ref.watch(
    diaryListByDateRangeProvider(
      (start: query.start, end: query.end),
    ).future,
  );
  final args = <String, dynamic>{
    'records': records,
    'start': query.start,
    'end': query.end,
  };
  switch (query.tab) {
    case StatTab.sleep:
      return compute(_calcSleepStats, args);
    case StatTab.diet:
      return compute(_calcDietStats, args);
    case StatTab.finance:
      return compute(_calcFinanceStats, args);
    case StatTab.mood:
      return compute(_calcMoodStats, args);
    case StatTab.activity:
      return compute(_calcActivityStats, args);
    case StatTab.score:
      // score tab 不走 statsProvider，由 DailyScoreStats 内部独立处理
      throw StateError('StatTab.score 不应调用 statsProvider');
  }
});
