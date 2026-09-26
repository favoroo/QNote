import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/diary_progress.dart';
import 'package:qnote_flutter/models/diary_record.dart';

DiaryRecord _record(String id, DateTime time, {bool deleted = false}) {
  return DiaryRecord(
    id: id,
    title: '记录$id',
    time: time,
    createdAt: time,
    updatedAt: time,
    isDeleted: deleted,
  );
}

void main() {
  group('computeDiaryProgress', () {
    test('空列表：0条、streak为0、未满环', () {
      final p = computeDiaryProgress([], DateTime(2026, 9, 25, 12));
      expect(p.todayCount, 0);
      expect(p.streakDays, 0);
      expect(p.isFull, isFalse);
      expect(p.ratio, 0);
      expect(p.remaining, 3);
      expect(p.todayPending, isTrue);
    });

    test('今天2条：计数正确、未满环、还差1条', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8)),
        _record('2', DateTime(2026, 9, 25, 12)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 2);
      expect(p.isFull, isFalse);
      expect(p.remaining, 1);
      expect(p.streakDays, 1);
      expect(p.todayPending, isFalse);
    });

    test('今天3条即满环，超目标后ratio封顶为1', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = List.generate(
        5,
        (i) => _record('$i', DateTime(2026, 9, 25, 8, i)),
      );
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 5);
      expect(p.isFull, isTrue);
      expect(p.ratio, 1);
      expect(p.remaining, 0);
    });

    test('连续3天每天≥1条：streak为3', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8)),
        _record('2', DateTime(2026, 9, 24, 8)),
        _record('3', DateTime(2026, 9, 23, 8)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.streakDays, 3);
    });

    test('今天0条、昨天有：不断连、标记todayPending', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 24, 8)),
        _record('2', DateTime(2026, 9, 23, 8)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 0);
      expect(p.streakDays, 2);
      expect(p.todayPending, isTrue);
    });

    test('中间断一天：streak只算断点之后', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8)),
        // 24号缺失
        _record('2', DateTime(2026, 9, 23, 8)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.streakDays, 1);
    });

    test('补记旧日期不计入今天', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 20, 8)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 0);
      expect(p.streakDays, 0);
    });

    test('已删除记录不计入', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8), deleted: true),
        _record('2', DateTime(2026, 9, 25, 9)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 1);
    });

    test('跨天睡眠按主体时长归属（与时间线口径一致）', () {
      final now = DateTime(2026, 9, 25, 12);
      // 24号23点睡到25号7点，主体在25号，应归属今天
      final sleep = DiaryRecord(
        id: 'sleep',
        title: '睡觉',
        time: DateTime(2026, 9, 24, 23),
        startTime: DateTime(2026, 9, 24, 23),
        endTime: DateTime(2026, 9, 25, 7),
        createdAt: DateTime(2026, 9, 25, 7),
        updatedAt: DateTime(2026, 9, 25, 7),
      );
      final p = computeDiaryProgress([sleep], now);
      expect(p.todayCount, 1);
    });

    test('maxPerDay记录历史单日最大', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8)),
        _record('2', DateTime(2026, 9, 24, 8)),
        _record('3', DateTime(2026, 9, 24, 9)),
        _record('4', DateTime(2026, 9, 24, 10)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.maxPerDay, 3);
    });

    test('运动健康自动同步的日结卡不计入今天', () {
      final now = DateTime(2026, 9, 25, 12);
      final healthCard = DiaryRecord(
        id: 'health',
        title: '运动健康',
        time: DateTime(2026, 9, 25, 23),
        bodyState: const {'source': 'mi_fitness', 'type': 'daily_summary'},
        createdAt: DateTime(2026, 9, 25, 23),
        updatedAt: DateTime(2026, 9, 25, 23),
      );
      final p = computeDiaryProgress([healthCard], now);
      expect(p.todayCount, 0);
      expect(p.todayPending, isTrue);
      expect(isSystemSyncedHealthRecord(healthCard), isTrue);
    });

    test('只有健康卡的日子不能续上streak', () {
      final now = DateTime(2026, 9, 25, 12);
      final healthCard = DiaryRecord(
        id: 'health',
        title: '运动健康',
        time: DateTime(2026, 9, 24, 23),
        bodyState: const {'source': 'mi_fitness', 'type': 'daily_summary'},
        createdAt: DateTime(2026, 9, 24, 23),
        updatedAt: DateTime(2026, 9, 24, 23),
      );
      final records = [
        healthCard,
        _record('1', DateTime(2026, 9, 25, 8)),
      ];
      final p = computeDiaryProgress(records, now);
      // 24号只有自动同步，不算连续，streak 只有今天
      expect(p.streakDays, 1);
    });

    test('健康卡不计入maxPerDay，不触发假破纪录', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8)),
        DiaryRecord(
          id: 'health',
          title: '运动健康',
          time: DateTime(2026, 9, 25, 23),
          bodyState: const {'source': 'mi_fitness', 'type': 'daily_summary'},
          createdAt: DateTime(2026, 9, 25, 23),
          updatedAt: DateTime(2026, 9, 25, 23),
        ),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 1);
      expect(p.maxPerDay, 1);
    });
  });

  group('computeStreakSummary', () {
    final now = DateTime(2026, 9, 25, 12);

    /// 按「几天前 → 当天条数」造数据；同一天内用不同小时避免互相覆盖。
    List<DiaryRecord> byDays(Map<int, int> perDay) {
      final records = <DiaryRecord>[];
      perDay.forEach((daysAgo, count) {
        for (var i = 0; i < count; i++) {
          final t = DateTime(2026, 9, 25 - daysAgo, 8, i);
          records.add(_record('$daysAgo-$i', t));
        }
      });
      return records;
    }

    test('空列表：全为0且今日待记', () {
      final s = computeStreakSummary([], now);
      expect(s.recordStreak, 0);
      expect(s.recordStreakLongest, 0);
      expect(s.fullStreak, 0);
      expect(s.fullStreakLongest, 0);
      expect(s.windowRecordedDays, 0);
      expect(s.windowFullDays, 0);
      expect(s.todayPending, isTrue);
    });

    test('连续5天每天1条：记录连续保住，达标连续为0', () {
      final s = computeStreakSummary(byDays({0: 1, 1: 1, 2: 1, 3: 1, 4: 1}), now);
      expect(s.recordStreak, 5);
      expect(s.recordStreakLongest, 5);
      expect(s.fullStreak, 0);
      expect(s.fullStreakLongest, 0);
      expect(s.windowRecordedDays, 5);
      expect(s.windowFullDays, 0);
      expect(s.todayPending, isFalse);
    });

    test('断档后取历史最长，当前连续只算断点之后', () {
      // 今天起连续 2 天；更早有一段 5 天
      final s = computeStreakSummary(byDays({0: 1, 1: 1, 6: 1, 7: 1, 8: 1, 9: 1, 10: 1}), now);
      expect(s.recordStreak, 2);
      expect(s.recordStreakLongest, 5);
    });

    test('达标口径独立：今天没记满则达标连续从更早断开', () {
      final s = computeStreakSummary(byDays({0: 1, 1: 3, 2: 3, 3: 3}), now);
      expect(s.recordStreak, 4);
      expect(s.recordStreakLongest, 4);
      // 今天只有 1 条，达标连续从昨天回溯：1、2、3 号前三天满足
      expect(s.fullStreak, 3);
      expect(s.fullStreakLongest, 3);
      expect(s.windowRecordedDays, 4);
      expect(s.windowFullDays, 3);
    });

    test('今天0条时两个口径都从昨天起算，不断连', () {
      final s = computeStreakSummary(byDays({1: 3, 2: 3}), now);
      expect(s.todayCount, 0);
      expect(s.todayPending, isTrue);
      expect(s.recordStreak, 2);
      expect(s.fullStreak, 2);
    });

    test('窗口只统计近30天，第31天不计入', () {
      final s = computeStreakSummary(byDays({0: 1, 29: 1, 30: 1}), now);
      expect(s.windowRecordedDays, 2);
      expect(s.windowDays, 30);
    });

    test('自定义窗口天数生效', () {
      final s = computeStreakSummary(byDays({0: 1, 1: 1, 2: 1}), now, windowDays: 2);
      expect(s.windowDays, 2);
      expect(s.windowRecordedDays, 2);
    });

    test('软删与系统同步健康卡都不计入连续', () {
      final healthCard = DiaryRecord(
        id: 'health',
        title: '运动健康',
        time: DateTime(2026, 9, 23, 23),
        bodyState: const {'source': 'mi_fitness'},
        createdAt: DateTime(2026, 9, 23, 23),
        updatedAt: DateTime(2026, 9, 23, 23),
      );
      final records = [
        ...byDays({0: 1, 1: 1}),
        _record('deleted', DateTime(2026, 9, 23, 8), deleted: true),
        healthCard,
      ];
      final s = computeStreakSummary(records, now);
      // 23 号只有一张软删记录和一张自动同步卡，都不算，连续停在 24 号
      expect(s.recordStreak, 2);
      expect(s.recordStreakLongest, 2);
      expect(s.windowRecordedDays, 2);
    });

    test('目标条数非法时回落到3，与今日完整度口径一致', () {
      final s = computeStreakSummary(byDays({0: 3, 1: 3}), now, target: 0);
      expect(s.target, 3);
      expect(s.fullStreak, 2);
      expect(s.windowFullDays, 2);
    });
  });
}
