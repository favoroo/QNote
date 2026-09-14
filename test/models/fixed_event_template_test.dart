import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';

void main() {
  group('FixedEventTemplate Tests', () {
    test('should construct with default single period if not specified', () {
      final now = DateTime.now();
      final template = FixedEventTemplate(
        id: '1',
        name: 'Work',
        startTime: '08:30',
        endTime: '18:00',
        createdAt: now,
        updatedAt: now,
      );

      expect(template.timePeriods.length, 1);
      expect(template.timePeriods[0].startTime, '08:30');
      expect(template.timePeriods[0].endTime, '18:00');
      expect(template.formattedTimeRange, '08:30-18:00');
    });

    test('should construct with multiple periods', () {
      final now = DateTime.now();
      final periods = [
        TimePeriod(startTime: '08:30', endTime: '12:00'),
        TimePeriod(startTime: '13:30', endTime: '18:00'),
      ];
      final template = FixedEventTemplate(
        id: '2',
        name: 'Work',
        startTime: '08:30',
        endTime: '12:00',
        timePeriods: periods,
        createdAt: now,
        updatedAt: now,
      );

      expect(template.timePeriods.length, 2);
      expect(template.timePeriods[0].startTime, '08:30');
      expect(template.timePeriods[1].endTime, '18:00');
      expect(template.formattedTimeRange, '08:30-12:00, 13:30-18:00');
    });

    test('roundtrip serialization/deserialization', () {
      final now = DateTime(2026, 6, 23, 12, 0);
      final periods = [
        TimePeriod(startTime: '08:30', endTime: '12:00'),
        TimePeriod(startTime: '13:30', endTime: '18:00'),
      ];
      final template = FixedEventTemplate(
        id: '3',
        name: 'Split Work',
        startTime: '08:30',
        endTime: '12:00',
        timePeriods: periods,
        isTimePoint: false,
        content: '忙碌的一天',
        tags: ['activity'],
        tagFields: {
          'activity': {'duration': '8.0'}
        },
        sortOrder: 5,
        isEnabled: true,
        createdAt: now,
        updatedAt: now,
      );

      final map = template.toMap();
      final restored = FixedEventTemplate.fromMap(map);

      expect(restored.id, '3');
      expect(restored.name, 'Split Work');
      expect(restored.startTime, '08:30');
      expect(restored.endTime, '12:00'); // backward compatibility first period's end time
      expect(restored.isTimePoint, false);
      expect(restored.content, '忙碌的一天');
      expect(restored.tags, ['activity']);
      expect(restored.tagFields['activity']?['duration'], '8.0');
      expect(restored.sortOrder, 5);
      expect(restored.isEnabled, true);
      expect(restored.timePeriods.length, 2);
      expect(restored.timePeriods[0].startTime, '08:30');
      expect(restored.timePeriods[1].endTime, '18:00');
      expect(restored.formattedTimeRange, '08:30-12:00, 13:30-18:00');
    });
  });
}
