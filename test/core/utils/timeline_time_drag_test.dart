import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/timeline_time_drag.dart';
import 'package:qnote_flutter/models/diary_record.dart';

DiaryRecord _record({required DateTime time, DateTime? startTime, DateTime? endTime}) {
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
    final anchor = DateTime(2026, 11, 11, 9, 43);

    test('无位移不产生时间变化', () {
      expect(resolveTimelineDragDeltaMinutes(anchor: anchor, contentDeltaPx: 0, pixelsPerMinute: pixelsPerMinute), 0);
    });

    test('位移不足半个档位时保持原时间', () {
      // 8px ≈ 5 分钟，不足 2.5 分钟（4px）视为手抖
      expect(resolveTimelineDragDeltaMinutes(anchor: anchor, contentDeltaPx: 3, pixelsPerMinute: pixelsPerMinute), 0);
      expect(resolveTimelineDragDeltaMinutes(anchor: anchor, contentDeltaPx: -3, pixelsPerMinute: pixelsPerMinute), 0);
    });

    test('按拖动后的绝对时刻吸附到 5 分钟整点', () {
      // 09:43 + 5 分钟 = 09:48 → 吸附到 09:50
      expect(resolveTimelineDragDeltaMinutes(anchor: anchor, contentDeltaPx: 8, pixelsPerMinute: pixelsPerMinute), 7);
      // 09:43 - 5 分钟 = 09:38 → 吸附到 09:40
      expect(resolveTimelineDragDeltaMinutes(anchor: anchor, contentDeltaPx: -8, pixelsPerMinute: pixelsPerMinute), -3);
      // 48px = 一个完整节点 = 30 分钟：09:43 + 30 分钟 = 10:13 → 吸附到 10:15
      expect(resolveTimelineDragDeltaMinutes(anchor: anchor, contentDeltaPx: 48, pixelsPerMinute: pixelsPerMinute), 32);
    });

    test('整点档位原时间按 5 分钟步进', () {
      final onGrid = DateTime(2026, 11, 11, 9, 45);
      expect(resolveTimelineDragDeltaMinutes(anchor: onGrid, contentDeltaPx: 8, pixelsPerMinute: pixelsPerMinute), 5);
      expect(resolveTimelineDragDeltaMinutes(anchor: onGrid, contentDeltaPx: -8, pixelsPerMinute: pixelsPerMinute), -5);
    });

    test('非法像素比例兜底为 1', () {
      expect(
        resolveTimelineDragDeltaMinutes(anchor: DateTime(2026, 11, 11, 9, 45), contentDeltaPx: 10, pixelsPerMinute: 0),
        10,
      );
    });
  });

  group('resolveTimelineTimeShift', () {
    test('单点记录向下拖动 30 分钟', () {
      final record = _record(time: DateTime(2026, 11, 11, 9));
      final shift = resolveTimelineTimeShift(record: record, contentDeltaPx: 48, pixelsPerMinute: pixelsPerMinute);

      expect(shift.deltaMinutes, 30);
      expect(shift.isChanged, isTrue);
      expect(shift.time, DateTime(2026, 11, 11, 9, 30));
      expect(shift.startTime, isNull);
      expect(shift.endTime, isNull);
    });

    test('非整点记录拖动后落在 5 分钟整点', () {
      final record = _record(time: DateTime(2026, 11, 11, 9, 43));
      final shift = resolveTimelineTimeShift(record: record, contentDeltaPx: 8, pixelsPerMinute: pixelsPerMinute);

      expect(shift.deltaMinutes, 7);
      expect(shift.time, DateTime(2026, 11, 11, 9, 50));
    });

    test('时间段记录整体平移且时长不变', () {
      final record = _record(
        time: DateTime(2026, 11, 11, 9),
        startTime: DateTime(2026, 11, 11, 9),
        endTime: DateTime(2026, 11, 11, 10, 30),
      );
      final shift = resolveTimelineTimeShift(record: record, contentDeltaPx: -16, pixelsPerMinute: pixelsPerMinute);

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
      final shift = resolveTimelineTimeShift(record: record, contentDeltaPx: -480, pixelsPerMinute: pixelsPerMinute);

      expect(shift.time, DateTime(2026, 11, 11, 0));
      expect(shift.deltaMinutes, -10);
    });

    test('向后拖动不跨出当天', () {
      final record = _record(time: DateTime(2026, 11, 11, 23, 50));
      final shift = resolveTimelineTimeShift(record: record, contentDeltaPx: 480, pixelsPerMinute: pixelsPerMinute);

      expect(shift.time, DateTime(2026, 11, 11, 23, 59));
      expect(shift.deltaMinutes, 9);
    });

    test('零位移返回原时间', () {
      final record = _record(time: DateTime(2026, 11, 11, 9, 12));
      final shift = resolveTimelineTimeShift(record: record, contentDeltaPx: 0, pixelsPerMinute: pixelsPerMinute);

      expect(shift.isChanged, isFalse);
      expect(shift.time, record.time);
    });
  });

  group('formatTimelineDragTimeLabel', () {
    test('单点只显示时分', () {
      expect(formatTimelineDragTimeLabel(DateTime(2026, 11, 11, 9, 5)), '09:05');
    });

    test('同日时间段使用短横线', () {
      expect(
        formatTimelineDragTimeLabel(DateTime(2026, 11, 11, 9), end: DateTime(2026, 11, 11, 10, 30)),
        '09:00–10:30',
      );
    });

    test('跨天结束时间标注次日', () {
      expect(formatTimelineDragTimeLabel(DateTime(2026, 11, 11, 23), end: DateTime(2026, 11, 12, 7)), '23:00–次日 07:00');
    });
  });
}
