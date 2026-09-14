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

  group('DiaryRecord toMap/fromMap roundtrip', () {
    test('should survive roundtrip with default values', () {
      final now = DateTime(2026, 6, 14, 10, 30);
      final record = DiaryRecord(
        id: 'test-1',
        title: '测试日记',
        time: now,
        createdAt: now,
        updatedAt: now,
      );

      final map = record.toMap();
      final restored = DiaryRecord.fromMap(map);

      expect(restored.id, record.id);
      expect(restored.title, record.title);
      expect(restored.time, record.time);
      expect(restored.content, '');
      expect(restored.mood, 3);
      expect(restored.weather, '');
      expect(restored.tags, isEmpty);
      expect(restored.photos, isEmpty);
      expect(restored.isDeleted, false);
    });

    test('should survive roundtrip with full values', () {
      final now = DateTime(2026, 6, 14, 10, 30);
      final record = DiaryRecord(
        id: 'test-2',
        title: '完整记录',
        time: now,
        startTime: DateTime(2026, 6, 14, 9, 0),
        endTime: DateTime(2026, 6, 14, 11, 0),
        tags: ['tag1', 'tag2'],
        displayTag: 'tag1',
        content: '正文内容',
        bodyState: {'key': 'value'},
        photos: ['photo1.jpg'],
        colorMark: '#FF0000',
        mood: 5,
        weather: '晴',
        folderId: 'folder-1',
        createdAt: now,
        updatedAt: now,
        isDeleted: true,
      );

      final map = record.toMap();
      final restored = DiaryRecord.fromMap(map);

      expect(restored.id, record.id);
      expect(restored.title, record.title);
      expect(restored.startTime, record.startTime);
      expect(restored.endTime, record.endTime);
      expect(restored.tags, record.tags);
      expect(restored.displayTag, record.displayTag);
      expect(restored.content, record.content);
      expect(restored.bodyState, record.bodyState);
      expect(restored.photos, record.photos);
      expect(restored.colorMark, record.colorMark);
      expect(restored.mood, record.mood);
      expect(restored.weather, record.weather);
      expect(restored.folderId, record.folderId);
      expect(restored.isDeleted, true);
    });
  });

  group('DiaryRecord copyWith', () {
    test('should return new instance with changed fields', () {
      final now = DateTime(2026, 6, 14);
      final record = DiaryRecord(
        id: '1',
        title: '原标题',
        time: now,
        createdAt: now,
        updatedAt: now,
      );

      final copied = record.copyWith(title: '新标题', mood: 5);
      expect(copied.title, '新标题');
      expect(copied.mood, 5);
      expect(copied.id, record.id);
      expect(copied.time, record.time);
    });

    test('should not mutate original', () {
      final now = DateTime(2026, 6, 14);
      final record = DiaryRecord(
        id: '1',
        title: '原标题',
        time: now,
        createdAt: now,
        updatedAt: now,
      );

      record.copyWith(title: '新标题');
      expect(record.title, '原标题');
    });
  });

  group('DiaryRecord getEffectiveDate', () {
    test('should return time date when no startTime/endTime', () {
      final now = DateTime(2026, 6, 14, 15, 30);
      final record = DiaryRecord(
        id: '1',
        title: 'Test',
        time: now,
        createdAt: now,
        updatedAt: now,
      );
      expect(record.getEffectiveDate(), DateTime(2026, 6, 14));
    });

    test('should return start day for same-day event', () {
      final record = DiaryRecord(
        id: '1',
        title: 'Test',
        time: DateTime(2026, 6, 14),
        startTime: DateTime(2026, 6, 14, 9, 0),
        endTime: DateTime(2026, 6, 14, 17, 0),
        createdAt: DateTime(2026, 6, 14),
        updatedAt: DateTime(2026, 6, 14),
      );
      expect(record.getEffectiveDate(), DateTime(2026, 6, 14));
    });

    test('should return end day when more time falls in end day', () {
      final record = DiaryRecord(
        id: '1',
        title: 'Test',
        time: DateTime(2026, 6, 14),
        startTime: DateTime(2026, 6, 14, 22, 0), // 2h in day 1
        endTime: DateTime(2026, 6, 15, 8, 0),   // 8h in day 2
        createdAt: DateTime(2026, 6, 14),
        updatedAt: DateTime(2026, 6, 14),
      );
      expect(record.getEffectiveDate(), DateTime(2026, 6, 15));
    });
  });

  group('DiaryRecord belongsToDate', () {
    test('should match when time falls on the date', () {
      final record = DiaryRecord(
        id: '1',
        title: 'Test',
        time: DateTime(2026, 6, 14, 15, 0),
        createdAt: DateTime(2026, 6, 14),
        updatedAt: DateTime(2026, 6, 14),
      );
      expect(record.belongsToDate(DateTime(2026, 6, 14)), true);
      expect(record.belongsToDate(DateTime(2026, 6, 15)), false);
    });
  });
}
