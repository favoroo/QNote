import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';

void main() {
  group('DiaryRecord getDisplayTime tests', () {
    test('Should return normal time when startTime and endTime are null', () {
      final now = DateTime.now();
      final record = DiaryRecord(
        id: '1',
        title: 'Test',
        time: now,
        createdAt: now,
        updatedAt: now,
      );
      expect(record.getDisplayTime(), now);
    });

    test('Should return endTime when startTime and endTime are on the same day', () {
      final now = DateTime.now();
      final start = DateTime(2026, 6, 2, 12, 0);
      final end = DateTime(2026, 6, 2, 13, 0);
      final record = DiaryRecord(
        id: '2',
        title: 'Same Day Event',
        time: now,
        startTime: start,
        endTime: end,
        createdAt: now,
        updatedAt: now,
      );
      expect(record.getDisplayTime(), end);
    });

    test('Should return endTime when event spans across days and belongs to the second day', () {
      final now = DateTime.now();
      final start = DateTime(2026, 6, 2, 22, 0); // 2 hours in day 1
      final end = DateTime(2026, 6, 3, 8, 0);   // 8 hours in day 2
      final record = DiaryRecord(
        id: '3',
        title: 'Sleep Event (Belongs to Day 2)',
        time: now,
        startTime: start,
        endTime: end,
        createdAt: now,
        updatedAt: now,
      );
      expect(record.getDisplayTime(), end);
    });

    test('Should return 23:30 of the first day when event spans across days and belongs to the first day', () {
      final now = DateTime.now();
      final start = DateTime(2026, 6, 2, 20, 0); // 4 hours in day 1
      final end = DateTime(2026, 6, 3, 1, 0);   // 1 hour in day 2
      final record = DiaryRecord(
        id: '4',
        title: 'Late Night Event (Belongs to Day 1)',
        time: now,
        startTime: start,
        endTime: end,
        createdAt: now,
        updatedAt: now,
      );
      expect(record.getDisplayTime(), DateTime(2026, 6, 2, 23, 30));
    });
  });
}
