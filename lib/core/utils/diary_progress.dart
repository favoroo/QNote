import 'package:qnote_flutter/models/diary_record.dart';

/// 今日完整度与连续记录的纯计算结果。
///
/// 抽成纯函数的原因：streak 回溯、跨天归属、满环判定都只依赖记录列表与
/// 当前时间，放在页面里只能靠起 App 点一点验证；抽出后单测可直接锁住。
class DiaryProgress {
  const DiaryProgress({
    required this.todayCount,
    required this.target,
    required this.streakDays,
    required this.maxPerDay,
    required this.todayPending,
  });

  /// 归属今天的记录条数（已过滤删除）。
  final int todayCount;

  /// 每日目标条数，默认 3。
  final int target;

  /// 连续有记录的天数（每天≥1条即连续）。
  final int streakDays;

  /// 历史单日最大条数，用于“破纪录”庆祝判定。
  final int maxPerDay;

  /// 今天尚无记录但 streak 从昨天起算时为 true，
  /// UI 据此显示“今日未记，记一条延续”。
  final bool todayPending;

  /// 今日是否达到满环。
  bool get isFull => todayCount >= target;

  /// 圆环进度 0~1。
  double get ratio {
    if (target <= 0) {
      return 0;
    }
    final r = todayCount / target;
    return r > 1 ? 1 : r;
  }

  /// 还差几条满环，满环后为 0。
  int get remaining => isFull ? 0 : target - todayCount;
}

/// 记录坚持度汇总，供统计页展示。
///
/// 只暴露聚合数字：日桶用的是本文件私有的非补零 key，跨模块传递会和
/// ScoreHeatmap / `getActiveDates` 的补零 `YYYY-MM-DD` 打架。
class StreakSummary {
  const StreakSummary({
    required this.target,
    required this.todayCount,
    required this.windowDays,
    required this.recordStreak,
    required this.recordStreakLongest,
    required this.fullStreak,
    required this.fullStreakLongest,
    required this.windowRecordedDays,
    required this.windowFullDays,
  });

  /// 每日目标条数，达标口径以此为准。
  final int target;

  /// 归属今天的记录条数。
  final int todayCount;

  /// 统计窗口天数（近 N 天，含今天）。
  final int windowDays;

  /// 当前连续记录天数（当天≥1条即算，口径同 [DiaryProgress.streakDays]）。
  final int recordStreak;

  /// 历史最长连续记录天数。
  final int recordStreakLongest;

  /// 当前连续达标天数（每天≥[target]条）。
  final int fullStreak;

  /// 历史最长连续达标天数。
  final int fullStreakLongest;

  /// 窗口内“有记录”的天数。
  final int windowRecordedDays;

  /// 窗口内“达标”的天数。
  final int windowFullDays;

  /// 今天还没记，连续记录随时会断。
  bool get todayPending => todayCount == 0;
}

/// 计算今日完整度与连续天数。
///
/// 系统自动同步的运动健康记录（`bodyState.source == 'mi_fitness'`，
/// 含日结汇总/单次运动/睡眠卡片）是否计入完整度。
///
/// 不计入：同步服务每天自动落一条日结，再小的手动记录都会被“保底不断连”，
/// 连续天数就失去了意义；与删除页不可删健康卡片的口径一致。
bool isSystemSyncedHealthRecord(DiaryRecord r) {
  final bs = r.bodyState;
  return bs != null && bs['source'] == 'mi_fitness';
}

/// 按“归属日”聚合记录条数。
///
/// - 当天归属一律用 [DiaryRecord.getEffectiveDate]（跨天睡眠按主体时长归属），
///   与时间线 `_buildRecordsByDate` 口径一致，避免圆环与列表打架。
/// - 已删除（`isDeleted`）与系统自动同步的健康记录不计入。
///
/// 返回的 key 是本文件私有的非补零 `y-m-d`（[_dayKey]），
/// 只在 diary_progress 内部流转，不要交给其它模块按日期串比对。
Map<String, int> countRecordsByDay(List<DiaryRecord> records) {
  final countByDay = <String, int>{};
  for (final r in records) {
    if (r.isDeleted || isSystemSyncedHealthRecord(r)) {
      continue;
    }
    final key = _dayKey(r.getEffectiveDate());
    countByDay[key] = (countByDay[key] ?? 0) + 1;
  }
  return countByDay;
}

/// 从今天往前回溯的连续天数；今天不满足 [minPerDay] 时从昨天起算（不断连）。
///
/// [minPerDay] 必须 ≥ 1，否则回溯条件恒真会死循环。
int _backtrackStreak(
  Map<String, int> countByDay,
  DateTime today, {
  required int minPerDay,
}) {
  var cursor = today;
  if ((countByDay[_dayKey(cursor)] ?? 0) < minPerDay) {
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  var streak = 0;
  while ((countByDay[_dayKey(cursor)] ?? 0) >= minPerDay) {
    streak++;
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  return streak;
}

/// 历史最长连续天数。
///
/// 对满足 [minPerDay] 的日期排序后一次扫描相邻间隔，不用逐日 while 回溯：
/// 全量历史可能有上千天，逐日推进会随数据量线性变差。
int _longestStreak(Map<String, int> countByDay, {required int minPerDay}) {
  final days = <DateTime>[];
  for (final entry in countByDay.entries) {
    if (entry.value < minPerDay) {
      continue;
    }
    final d = _parseDayKey(entry.key);
    if (d != null) {
      days.add(d);
    }
  }
  if (days.isEmpty) {
    return 0;
  }

  days.sort();
  var best = 1;
  var run = 1;
  for (var i = 1; i < days.length; i++) {
    // 用 UTC 日界算差值，避开本地时区夏令时切换导致的 23/25 小时误差
    final gap = days[i].difference(days[i - 1]).inDays;
    run = gap == 1 ? run + 1 : 1;
    if (run > best) {
      best = run;
    }
  }
  return best;
}

/// - 当天归属与剔除口径见 [countRecordsByDay]。
/// - streak：今天有记录从今天起算，否则从昨天起算（不断连，
///   但标记 [DiaryProgress.todayPending] 提醒补记）。
DiaryProgress computeDiaryProgress(
  List<DiaryRecord> records,
  DateTime now, {
  int target = 3,
}) {
  final safeTarget = target <= 0 ? 3 : target;
  final today = DateTime(now.year, now.month, now.day);

  final countByDay = countRecordsByDay(records);
  final todayCount = countByDay[_dayKey(today)] ?? 0;

  int maxPerDay = 0;
  for (final c in countByDay.values) {
    if (c > maxPerDay) {
      maxPerDay = c;
    }
  }

  return DiaryProgress(
    todayCount: todayCount,
    target: safeTarget,
    streakDays: _backtrackStreak(countByDay, today, minPerDay: 1),
    maxPerDay: maxPerDay,
    todayPending: todayCount == 0,
  );
}

/// 计算记录坚持度汇总（当前/最长连续、达标口径连续、窗口统计）。
///
/// 需要全量记录才能算出“历史最长”，调用方应传完整日记列表而非某天子集。
StreakSummary computeStreakSummary(
  List<DiaryRecord> records,
  DateTime now, {
  int target = 3,
  int windowDays = 30,
}) {
  final safeTarget = target <= 0 ? 3 : target;
  final safeWindow = windowDays <= 0 ? 30 : windowDays;
  final today = DateTime(now.year, now.month, now.day);

  final countByDay = countRecordsByDay(records);
  final todayCount = countByDay[_dayKey(today)] ?? 0;

  var windowRecordedDays = 0;
  var windowFullDays = 0;
  for (var i = 0; i < safeWindow; i++) {
    // 用日期分量回退，避免 Duration 减法在时区切换日跳天
    final day = DateTime(today.year, today.month, today.day - i);
    final count = countByDay[_dayKey(day)] ?? 0;
    if (count > 0) {
      windowRecordedDays++;
    }
    if (count >= safeTarget) {
      windowFullDays++;
    }
  }

  return StreakSummary(
    target: safeTarget,
    todayCount: todayCount,
    windowDays: safeWindow,
    recordStreak: _backtrackStreak(countByDay, today, minPerDay: 1),
    recordStreakLongest: _longestStreak(countByDay, minPerDay: 1),
    fullStreak: _backtrackStreak(countByDay, today, minPerDay: safeTarget),
    fullStreakLongest: _longestStreak(countByDay, minPerDay: safeTarget),
    windowRecordedDays: windowRecordedDays,
    windowFullDays: windowFullDays,
  );
}

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

/// [_dayKey] 的逆运算；解析失败返回 null（脏数据不让整个统计崩掉）。
DateTime? _parseDayKey(String key) {
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
  return DateTime.utc(y, m, d);
}
