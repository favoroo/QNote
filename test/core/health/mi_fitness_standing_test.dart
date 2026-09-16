import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MiFitness 站立数据解析测试', () {
    test('解析带 daily_report 汇总的 valid_stand 数据', () {
      final mockData = [
        {
          'time': 1710000000,
          'tag': 'hourly',
          'value': json.encode({'count': 1}),
        },
        {
          'time': 1710003600,
          'tag': 'hourly',
          'value': json.encode({'count': 1}),
        },
        {
          'time': 1710036000,
          'tag': 'daily_report',
          'value': json.encode({'count': 12}),
        },
      ];

      int totalStanding = 0;
      int? dailyReportStanding;
      final standingHourSet = <int>{};

      for (final item in mockData) {
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;
        final tag = item['tag'] as String? ?? '';
        final standVal = valJson['count'] ??
            valJson['standing_count'] ??
            valJson['stand_count'] ??
            valJson['standing'] ??
            valJson['stand'];

        if (tag == 'daily_report' && standVal is num) {
          dailyReportStanding = standVal.toInt();
        }
        if (standVal is num && standVal.toInt() > 1 && dailyReportStanding == null) {
          dailyReportStanding = standVal.toInt();
        }

        final timeSec = (item['time'] as num?)?.toInt() ?? 0;
        final isStanding = (standVal is num && standVal.toInt() >= 1) ||
            valJson['has_stand'] == true ||
            valJson['has_stand'] == 1;

        if (timeSec > 0 && isStanding) {
          final dt = DateTime.fromMillisecondsSinceEpoch(timeSec * 1000);
          standingHourSet.add(dt.hour);
        }
      }

      if (dailyReportStanding != null && dailyReportStanding > 0) {
        totalStanding = dailyReportStanding;
      } else if (standingHourSet.isNotEmpty) {
        totalStanding = standingHourSet.length;
      }

      expect(totalStanding, equals(12));
    });

    test('解析无 daily_report 但按小时打点的 valid_stand 数据', () {
      final mockData = [
        {
          'time': 1710000000, // 某个具体时间
          'tag': '',
          'value': json.encode({'count': 1}),
        },
        {
          'time': 1710000060, // 同一个小时内
          'tag': '',
          'value': json.encode({'count': 1}),
        },
        {
          'time': 1710003600, // 下一个小时
          'tag': '',
          'value': json.encode({'count': 1}),
        },
      ];

      int totalStanding = 0;
      int? dailyReportStanding;
      final standingHourSet = <int>{};

      for (final item in mockData) {
        final valStr = item['value'] as String? ?? '{}';
        final valJson = json.decode(valStr) as Map<String, dynamic>;
        final tag = item['tag'] as String? ?? '';
        final standVal = valJson['count'] ??
            valJson['standing_count'] ??
            valJson['stand_count'] ??
            valJson['standing'] ??
            valJson['stand'];

        if (tag == 'daily_report' && standVal is num) {
          dailyReportStanding = standVal.toInt();
        }
        if (standVal is num && standVal.toInt() > 1 && dailyReportStanding == null) {
          dailyReportStanding = standVal.toInt();
        }

        final timeSec = (item['time'] as num?)?.toInt() ?? 0;
        final isStanding = (standVal is num && standVal.toInt() >= 1) ||
            valJson['has_stand'] == true ||
            valJson['has_stand'] == 1;

        if (timeSec > 0 && isStanding) {
          final dt = DateTime.fromMillisecondsSinceEpoch(timeSec * 1000);
          standingHourSet.add(dt.hour);
        }
      }

      if (dailyReportStanding != null && dailyReportStanding > 0) {
        totalStanding = dailyReportStanding;
      } else if (standingHourSet.isNotEmpty) {
        totalStanding = standingHourSet.length;
      }

      expect(totalStanding, equals(2));
    });
  });
}
