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
      expect(p.remaining, 5);
      expect(p.todayPending, isTrue);
    });

    test('今天3条：计数正确、未满环、还差2条', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = [
        _record('1', DateTime(2026, 9, 25, 8)),
        _record('2', DateTime(2026, 9, 25, 12)),
        _record('3', DateTime(2026, 9, 25, 18)),
      ];
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 3);
      expect(p.isFull, isFalse);
      expect(p.remaining, 2);
      expect(p.streakDays, 1);
      expect(p.todayPending, isFalse);
    });

    test('今天5条即满环，超目标后ratio封顶为1', () {
      final now = DateTime(2026, 9, 25, 12);
      final records = List.generate(
        7,
        (i) => _record('$i', DateTime(2026, 9, 25, 8, i)),
      );
      final p = computeDiaryProgress(records, now);
      expect(p.todayCount, 7);
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
  });
}
