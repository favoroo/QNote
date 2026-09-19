import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/screen_usage_info.dart';

/// 原生 → Dart 的字段契约测试。
///
/// 这里曾经出过一个静默 Bug：Kotlin 返回 `yesterdayTotalTime`，Dart 读
/// `yesterdayTotalTimeMs`，昨日值恒为 0，于是界面上永远显示
/// 「较昨日增加 X 小时」——用户截图里的今日 3小时49分钟、较昨日增加 3小时49分钟
/// 就是这个症状。键名一旦漂移没有任何报错，只能靠测试锁住。
void main() {
  group('TodayScreenUsage 契约', () {
    test('按 yesterdayTotalTimeMs 解析昨日时长', () {
      final usage = TodayScreenUsage.fromMap({
        'totalTime': 3 * 3600 * 1000 + 49 * 60 * 1000,
        'yesterdayTotalTimeMs': 5 * 3600 * 1000,
        'appList': <dynamic>[],
      });

      expect(usage.yesterdayTotalTimeMs, 5 * 3600 * 1000);
    });

    test('昨日更长时文案为减少，不再恒为增加', () {
      final usage = TodayScreenUsage.fromMap({
        'totalTime': 3 * 3600 * 1000 + 49 * 60 * 1000,
        'yesterdayTotalTimeMs': 5 * 3600 * 1000,
        'appList': <dynamic>[],
      });

      expect(usage.diffWithYesterdayMs, lessThan(0));
      expect(usage.diffDescription, contains('减少'));
      expect(usage.diffDescription, isNot(contains('增加')));
    });

    test('今日更长时文案为增加', () {
      final usage = TodayScreenUsage.fromMap({
        'totalTime': 6 * 3600 * 1000,
        'yesterdayTotalTimeMs': 2 * 3600 * 1000,
        'appList': <dynamic>[],
      });

      expect(usage.diffDescription, contains('增加'));
    });

    test('差值不足一分钟时视为持平', () {
      final usage = TodayScreenUsage.fromMap({
        'totalTime': 3600 * 1000,
        'yesterdayTotalTimeMs': 3600 * 1000 + 30 * 1000,
        'appList': <dynamic>[],
      });

      expect(usage.diffDescription, '与昨日基本持平');
    });

    test('缺失昨日字段时降级为 0 而不抛异常', () {
      final usage = TodayScreenUsage.fromMap({
        'totalTime': 3600 * 1000,
        'appList': <dynamic>[],
      });

      expect(usage.yesterdayTotalTimeMs, 0);
    });
  });

  group('时长格式化', () {
    test('整小时不追加「0分钟」', () {
      const usage = TodayScreenUsage(totalTimeMs: 2 * 3600 * 1000, yesterdayTotalTimeMs: 0, appList: []);
      expect(usage.formattedTotalTime, '2小时');
    });

    test('小时加分钟', () {
      const usage = TodayScreenUsage(
        totalTimeMs: 3 * 3600 * 1000 + 49 * 60 * 1000,
        yesterdayTotalTimeMs: 0,
        appList: [],
      );
      expect(usage.formattedTotalTime, '3小时49分钟');
    });

    test('不足一小时只显示分钟', () {
      const usage = TodayScreenUsage(
        totalTimeMs: 42 * 60 * 1000,
        yesterdayTotalTimeMs: 0,
        appList: [],
      );
      expect(usage.formattedTotalTime, '42分钟');
    });

    test('不足一分钟显示秒', () {
      const usage = TodayScreenUsage(
        totalTimeMs: 35 * 1000,
        yesterdayTotalTimeMs: 0,
        appList: [],
      );
      expect(usage.formattedTotalTime, '35秒');
    });
  });

  group('AppUsageInfo 解析', () {
    test('原生键名 totalTimeInForeground / icon', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final info = AppUsageInfo.fromMap({
        'packageName': 'com.ss.android.ugc.aweme',
        'appName': '抖音精选',
        'totalTimeInForeground': 71 * 60 * 1000,
        'lastTimeUsed': 0,
        'icon': bytes,
      });

      expect(info.appName, '抖音精选');
      expect(info.minutes, 71);
      expect(info.formattedDuration, '1小时11分钟');
      expect(info.iconBytes, bytes);
    });

    test('无图标时 iconBytes 为 null，UI 走兜底', () {
      final info = AppUsageInfo.fromMap({
        'packageName': 'com.uu.uuremote',
        'appName': 'uuremote',
        'totalTimeInForeground': 3 * 60 * 1000,
      });

      expect(info.iconBytes, isNull);
      expect(info.formattedDuration, '3分钟');
    });
  });

  group('DailyScreenTime', () {
    test('今日柱标签固定为「今日」', () {
      final today = DailyScreenTime.fromMap({
        'date': DateTime.now().millisecondsSinceEpoch,
        'totalTime': 3600 * 1000,
        'dayOfWeek': 6,
        'isToday': true,
      });

      expect(today.dayLabel, '今日');
      expect(today.hours, 1.0);
    });

    test('历史柱按星期显示', () {
      // 2026-09-14 是周一
      final monday = DailyScreenTime.fromMap({
        'date': DateTime(2026, 9, 14).millisecondsSinceEpoch,
        'totalTime': 30 * 60 * 1000,
        'dayOfWeek': 2,
        'isToday': false,
      });

      expect(monday.dayLabel, '周一');
      expect(monday.minutes, 30);
    });
  });
}
