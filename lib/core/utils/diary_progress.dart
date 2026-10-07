import 'package:qnote_flutter/models/diary_record.dart';

/// 今日完整度的纯计算结果。
///
/// 抽成纯函数的原因：跨天归属、满环判定都只依赖记录列表与当前时间，
/// 放在页面里只能靠起 App 点一点验证；抽出后单测可直接锁住。
class DiaryProgress {
  const DiaryProgress({
    required this.todayCount,
    required this.target,
    required this.maxPerDay,
  });

  /// 归属今天的记录条数（已过滤删除）。
  final int todayCount;

  /// 每日目标条数，默认 3。
  final int target;

  /// 历史单日最大条数，用于“破纪录”庆祝判定。
  final int maxPerDay;

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

/// 系统自动同步的运动健康记录（`bodyState.source == 'mi_fitness'`，
/// 含日结汇总/单次运动/睡眠卡片）是否计入完整度。
///
/// 不计入：同步服务每天自动落一条日结，会把今日条数与单日纪录无条件垫高，
/// 完整度圆环和“破纪录”判定都会失真；与删除页不可删健康卡片的口径一致。
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

/// 计算今日完整度。
///
/// 当天归属与剔除口径见 [countRecordsByDay]。
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
    maxPerDay: maxPerDay,
  );
}

String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
