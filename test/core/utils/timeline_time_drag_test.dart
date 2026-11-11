import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/timeline_time_drag.dart';
import 'package:qnote_flutter/models/diary_record.dart';

DiaryRecord _record({
  required DateTime time,
  DateTime? startTime,
  DateTime? endTime,
}) {
  return DiaryRecord(
    id: 'r1',
    title: '记录',
    time: time,
    startTime: startTime,
    endTime: endTime,
    createdAt: time,
    updatedAt: time,
  );
}

void main() {
  const pixelsPerMinute = 48 / 30;

  group('resolveTimelineDragDeltaMinutes', () {
    test('无位移不产生时间变化', () {
      expect(
        resolveTimelineDragDeltaMinutes(
          contentDeltaPx: 0,
          pixelsPerMinute: pixelsPerMinute,
        ),
        0,
      );
    });

    test('位移按 5 分钟吸附', () {
      // 8px ≈ 5 分钟
      expect(
        resolveTimelineDragDeltaMinutes(
          contentDeltaPx: 8,
          pixelsPerMinute: pixelsPerMinute,
        ),
        5,
      );
      expect(
        resolveTimelineDragDeltaMinutes(
          contentDeltaPx: -8,
          pixelsPerMinute: pixelsPerMinute,
        ),
        -5,
      );
      // 48px = 一个完整节点 = 30 分钟
      expect(
        resolveTimelineDragDeltaMinutes(
          contentDeltaPx: 48,
          pixelsPerMinute: pixelsPerMinute,
        ),
        30,
      );
    });

    test('非法像素比例兜底为 1', () {
      expect(
        resolveTimelineDragDeltaMinutes(contentDeltaPx: 10, pixelsPerMinute: 0),
        10,
      );
    });
  });

  group('resolveTimelineTimeShift', () {
    test('单点记录向下拖动 30 分钟', () {
      final record = _record(time: DateTime(2026, 11, 11, 9));
      final shift = resolveTimelineTimeShift(
        record: record,
        contentDeltaPx: 48,
        pixelsPerMinute: pixelsPerMinute,
      );

      expect(shift.deltaMinutes, 30);
      expect(shift.isChanged, isTrue);
      expect(shift.time, DateTime(2026, 11, 11, 9, 30));
      expect(shift.startTime, isNull);
      expect(shift.endTime, isNull);
    });

    test('时间段记录整体平移且时长不变', () {
      final record = _record(
        time: DateTime(2026, 11, 11, 9),
        startTime: DateTime(2026, 11, 11, 9),
        endTime: DateTime(2026, 11, 11, 10, 30),
      );
      final shift = resolveTimelineTimeShift(
        record: record,
        contentDeltaPx: -16,
        pixelsPerMinute: pixelsPerMinute,
      );

      expect(shift.deltaMinutes, -10);
      expect(shift.time, DateTime(2026, 11, 11, 8, 50));
      expect(shift.startTime, DateTime(2026, 11, 11, 8, 50));
      expect(shift.endTime, DateTime(2026, 11, 11, 10, 20));
      expect(
        shift.endTime!.difference(shift.startTime!).inMinutes,
        record.endTime!.difference(record.startTime!).inMinutes,
      );
    });

    test('向前拖动不跨出当天', () {
      final record = _record(time: DateTime(2026, 11, 11, 0, 10));
      final shift = resolveTimelineTimeShift(
        record: record,
        contentDeltaPx: -480,
        pixelsPerMinute: pixelsPerMinute,
      );

      expect(shift.time, DateTime(2026, 11, 11, 0));
      expect(shift.deltaMinutes, -10);
    });

    test('向后拖动不跨出当天', () {
      final record = _record(time: DateTime(2026, 11, 11, 23, 50));
      final shift = resolveTimelineTimeShift(
        record: record,
        contentDeltaPx: 480,
        pixelsPerMinute: pixelsPerMinute,
      );

      expect(shift.time, DateTime(2026, 11, 11, 23, 59));
      expect(shift.deltaMinutes, 9);
    });

    test('零位移返回原时间', () {
      final record = _record(time: DateTime(2026, 11, 11, 9, 12));
      final shift = resolveTimelineTimeShift(
        record: record,
        contentDeltaPx: 0,
        pixelsPerMinute: pixelsPerMinute,
      );

      expect(shift.isChanged, isFalse);
      expect(shift.time, record.time);
    });
  });

  group('formatTimelineDragTimeLabel', () {
    test('单点只显示时分', () {
      expect(
        formatTimelineDragTimeLabel(DateTime(2026, 11, 11, 9, 5)),
        '09:05',
      );
    });

    test('同日时间段使用短横线', () {
      expect(
        formatTimelineDragTimeLabel(
          DateTime(2026, 11, 11, 9),
          end: DateTime(2026, 11, 11, 10, 30),
        ),
        '09:00–10:30',
      );
    });

    test('跨天结束时间标注次日', () {
      expect(
        formatTimelineDragTimeLabel(
          DateTime(2026, 11, 11, 23),
          end: DateTime(2026, 11, 12, 7),
        ),
        '23:00–次日 07:00',
      );
    });
  });
}
