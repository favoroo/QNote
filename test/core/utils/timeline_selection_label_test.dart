import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/timeline_selection_label.dart';

void main() {
  final today = DateTime(2026, 11, 11);

  test('未选区间时只显示开始时间', () {
    final label = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 14, minute: 30),
      startDate: today,
      today: today,
    );

    expect(label.time, '14:30');
    expect(label.dayBadge, isNull);
  });

  test('同一天的区间用短横线连接', () {
    final label = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 14, minute: 30),
      endTime: const TimeOfDay(hour: 16, minute: 0),
      startDate: today,
      today: today,
    );

    expect(label.time, '14:30–16:00');
  });

  test('补零：个位数时分也要两位', () {
    final label = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 9, minute: 5),
      endTime: const TimeOfDay(hour: 10, minute: 0),
      startDate: today,
      today: today,
    );

    expect(label.time, '09:05–10:00');
  });

  test('跨天区间用次日/前日提示，避免读成时间倒流', () {
    final nextDay = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 23, minute: 30),
      endTime: const TimeOfDay(hour: 2, minute: 0),
      startDate: today,
      endDate: today.add(const Duration(days: 1)),
      today: today,
    );
    expect(nextDay.time, '23:30–次日 02:00');

    final prevDay = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 0, minute: 30),
      endTime: const TimeOfDay(hour: 23, minute: 0),
      startDate: today,
      endDate: today.subtract(const Duration(days: 1)),
      today: today,
    );
    expect(prevDay.time, '00:30–前日 23:00');
  });

  test('跨两天以上回落到绝对月-日', () {
    final label = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 8, minute: 0),
      endTime: const TimeOfDay(hour: 9, minute: 0),
      startDate: today,
      endDate: today.add(const Duration(days: 3)),
      today: today,
    );

    expect(label.time, '08:00–11-14 09:00');
  });

  test('日期角标：今天不标，昨天/明天用中文，更远用月-日', () {
    TimelineSelectionLabel labelFor(DateTime date) => buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 8, minute: 0),
      startDate: date,
      today: today,
    );

    expect(labelFor(today).dayBadge, isNull);
    expect(labelFor(today.subtract(const Duration(days: 1))).dayBadge, '昨天');
    expect(labelFor(today.add(const Duration(days: 1))).dayBadge, '明天');
    expect(labelFor(today.add(const Duration(days: 3))).dayBadge, '11-14');
    expect(labelFor(today.subtract(const Duration(days: 40))).dayBadge, '10-02');
  });

  test('角标按日期比较而不是 24 小时差：当天任意时刻都不算昨天', () {
    final label = buildTimelineSelectionLabel(
      startTime: const TimeOfDay(hour: 23, minute: 59),
      startDate: DateTime(2026, 11, 11, 23, 59),
      today: DateTime(2026, 11, 11, 0, 1),
    );

    expect(label.dayBadge, isNull);
  });
}
