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

/// - 当天归属一律用 [DiaryRecord.getEffectiveDate]（跨天睡眠按主体时长归属），
///   与时间线 `_buildRecordsByDate` 口径一致，避免圆环与列表打架。
/// - 已删除（`isDeleted`）与系统自动同步的健康记录不计入。
/// - streak：今天有记录从今天起算，否则从昨天起算（不断连，
///   但标记 [DiaryProgress.todayPending] 提醒补记）。
DiaryProgress computeDiaryProgress(
  List<DiaryRecord> records,
  DateTime now, {
  int target = 3,
}) {
  final safeTarget = target <= 0 ? 3 : target;
  final today = DateTime(now.year, now.month, now.day);

  final Map<String, int> countByDay = {};
  int todayCount = 0;

  for (final r in records) {
    if (r.isDeleted || isSystemSyncedHealthRecord(r)) {
      continue;
    }
    final d = r.getEffectiveDate();
    final key = _dayKey(d);
    countByDay[key] = (countByDay[key] ?? 0) + 1;
    if (d.year == today.year && d.month == today.month && d.day == today.day) {
      todayCount++;
    }
  }

  int maxPerDay = 0;
  for (final c in countByDay.values) {
    if (c > maxPerDay) {
      maxPerDay = c;
    }
  }

  // streak 回溯：今天有记录从今天起算，否则从昨天起算（不断连）。
  final todayPending = todayCount == 0;
  var cursor = todayPending
      ? today.subtract(const Duration(days: 1))
      : today;
  var streak = 0;
  while (countByDay[_dayKey(cursor)] != null &&
      countByDay[_dayKey(cursor)]! > 0) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }

  return DiaryProgress(
    todayCount: todayCount,
    target: safeTarget,
    streakDays: streak,
    maxPerDay: maxPerDay,
    todayPending: todayPending,
  );
}

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
