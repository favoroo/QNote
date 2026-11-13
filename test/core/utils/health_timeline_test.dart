import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/health_timeline.dart';

void main() {
  group('shouldShowHealthDailyPlaceholder', () {
    final today = DateTime(2026, 11, 13);

    test('今天与过去日期可以显示，未来日期不显示', () {
      expect(
        shouldShowHealthDailyPlaceholder(
          date: DateTime(2026, 11, 13, 23, 59),
          today: today,
          hasDailySummary: false,
          healthBound: true,
        ),
        isTrue,
      );
      expect(
        shouldShowHealthDailyPlaceholder(
          date: DateTime(2026, 1, 1),
          today: today,
          hasDailySummary: false,
          healthBound: true,
        ),
        isTrue,
      );
      expect(
        shouldShowHealthDailyPlaceholder(
          date: DateTime(2026, 11, 14),
          today: today,
          hasDailySummary: false,
          healthBound: true,
        ),
        isFalse,
      );
    });

    test('已有日结卡或未绑定时不显示', () {
      expect(
        shouldShowHealthDailyPlaceholder(
          date: DateTime(2026, 11, 13),
          today: today,
          hasDailySummary: true,
          healthBound: true,
        ),
        isFalse,
      );
      expect(
        shouldShowHealthDailyPlaceholder(
          date: DateTime(2026, 11, 13),
          today: today,
          hasDailySummary: false,
          healthBound: false,
        ),
        isFalse,
      );
    });

    test('日期比较忽略时分秒', () {
      expect(
        shouldShowHealthDailyPlaceholder(
          date: DateTime(2026, 11, 13, 0, 1),
          today: DateTime(2026, 11, 13, 22, 30),
          hasDailySummary: false,
          healthBound: true,
        ),
        isTrue,
      );
    });
  });

  group('resolveHealthPlaceholderMode', () {
    test('未同步过 => unsynced', () {
      expect(resolveHealthPlaceholderMode(hasSynced: false, hasData: false), HealthPlaceholderMode.unsynced);
    });

    test('同步过但当天无数据 => syncedEmpty', () {
      expect(resolveHealthPlaceholderMode(hasSynced: true, hasData: false), HealthPlaceholderMode.syncedEmpty);
    });

    test('已有数据但缺日结卡 => syncedWithoutCard', () {
      expect(resolveHealthPlaceholderMode(hasSynced: true, hasData: true), HealthPlaceholderMode.syncedWithoutCard);
    });
  });
}
