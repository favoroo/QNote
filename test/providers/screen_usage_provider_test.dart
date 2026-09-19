import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/providers/screen_usage_provider.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';

/// 屏幕时长聚合口径测试。
///
/// 锁三件最容易算错的事：周起点、日均分母、环比是否同期截断。
/// 这三处错了，界面不会报错，只会给出一个看着合理但完全误导的数字。
void main() {
  ScreenUsageDaily day(DateTime date, int totalMs, {List<ScreenAppUsage> apps = const []}) {
    return ScreenUsageDaily(
      date: ScreenUsageDaily.dateKey(date),
      totalTimeMs: totalMs,
      topApps: apps,
      isComplete: true,
      createdAt: date,
      updatedAt: date,
    );
  }

  group('resolveScreenRange', () {
    // 以下边界断言统一使用完全过去的整周/整月/整年，
    // 避免「未过完的区间截断到今天」这一正确行为干扰边界校验。
    test('一周从周一开始、周日结束', () {
      // 2026-08-12 是周三
      final bounds = resolveScreenRange(TimeRangeType.week, DateTime(2026, 8, 12));

      expect(bounds.start, DateTime(2026, 8, 10));
      expect(bounds.end, DateTime(2026, 8, 16));
      expect(bounds.dataEnd, DateTime(2026, 8, 16));
      expect(bounds.spanDays, 7);
    });

    test('周日也归属它所在的那一周（周一为首日）', () {
      // 2026-08-16 是周日
      final bounds = resolveScreenRange(TimeRangeType.week, DateTime(2026, 8, 16));

      expect(bounds.start, DateTime(2026, 8, 10));
    });

    test('整月边界与天数', () {
      final bounds = resolveScreenRange(TimeRangeType.month, DateTime(2026, 8, 16));

      expect(bounds.start, DateTime(2026, 8, 1));
      expect(bounds.end, DateTime(2026, 8, 31));
      expect(bounds.spanDays, 31);
    });

    test('二月按实际天数收口', () {
      final bounds = resolveScreenRange(TimeRangeType.month, DateTime(2026, 2, 10));

      expect(bounds.end, DateTime(2026, 2, 28));
      expect(bounds.spanDays, 28);
    });

    test('整年边界', () {
      final bounds = resolveScreenRange(TimeRangeType.year, DateTime(2025, 9, 16));

      expect(bounds.start, DateTime(2025, 1, 1));
      expect(bounds.end, DateTime(2025, 12, 31));
      expect(bounds.spanDays, 365);
    });

    test('未过完的当月只统计到今天，上期取同样天数', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final bounds = resolveScreenRange(TimeRangeType.month, today);

      expect(bounds.dataEnd, today);
      expect(bounds.spanDays, today.day);
      expect(bounds.prevSpanDays, today.day, reason: '两期天数必须一致，否则环比永远偏低');
    });

    test('上期月末日数不足时按上期自然月末收口', () {
      // 3 月 31 日 → 2 月只有 28 天
      final bounds = resolveScreenRange(TimeRangeType.month, DateTime(2026, 3, 31));

      expect(bounds.prevStart, DateTime(2026, 2, 1));
      expect(bounds.prevEnd, DateTime(2026, 2, 28));
    });

    test('本周的上期为紧邻的前 7 天', () {
      final bounds = resolveScreenRange(TimeRangeType.week, DateTime(2026, 8, 12));

      expect(bounds.prevStart, DateTime(2026, 8, 3));
      expect(bounds.prevEnd, DateTime(2026, 8, 9));
      expect(bounds.prevSpanDays, bounds.spanDays);
    });
  });

  group('日均与 Top 榜合并', () {
    test('日均分母是有记录天数，不是自然天数', () {
      // 只采集到 3 天的整月：用自然天数会得出一个荒谬的低值
      const totalMs = 30 * 3600 * 1000;

      expect(ScreenUsageAggregate.computeAvg(totalMs, 3), 10 * 3600 * 1000);
      expect(ScreenUsageAggregate.computeAvg(totalMs, 0), 0);
    });

    test('跨天累计同一应用并按时长倒序', () {
      final days = [
        day(DateTime(2026, 9, 14), 5000, apps: [
          const ScreenAppUsage(packageName: 'com.a', appName: 'A', timeMs: 2000),
          const ScreenAppUsage(packageName: 'com.b', appName: 'B', timeMs: 3000),
        ]),
        day(DateTime(2026, 9, 15), 4000, apps: [
          const ScreenAppUsage(packageName: 'com.a', appName: 'A', timeMs: 4000),
        ]),
      ];

      final merged = ScreenUsageAggregate.mergeTopApps(days);

      expect(merged.first.packageName, 'com.a');
      expect(merged.first.timeMs, 6000);
      expect(merged.last.packageName, 'com.b');
    });

    test('明细全空时返回空榜而不报错', () {
      final merged = ScreenUsageAggregate.mergeTopApps([
        day(DateTime(2026, 9, 14), 1000),
      ]);

      expect(merged, isEmpty);
    });

    test('Top 榜按 limit 截断', () {
      final apps = List.generate(
        40,
        (i) => ScreenAppUsage(packageName: 'com.p$i', appName: 'P$i', timeMs: 100000 - i),
      );

      final merged = ScreenUsageAggregate.mergeTopApps([
        day(DateTime(2026, 9, 14), 1000, apps: apps),
      ], limit: 30);

      expect(merged.length, 30);
    });
  });

  group('时长与差值文案', () {
    test('formatScreenDuration 各量级', () {
      expect(formatScreenDuration(0), '0秒');
      expect(formatScreenDuration(45 * 1000), '45秒');
      expect(formatScreenDuration(42 * 60 * 1000), '42分钟');
      expect(formatScreenDuration(2 * 3600 * 1000), '2小时');
      expect(formatScreenDuration(3 * 3600 * 1000 + 49 * 60 * 1000), '3小时49分钟');
    });

    test('上期无数据时不谎报增减', () {
      expect(screenDurationDiffText(3600 * 1000, 0), '暂无昨日对比数据');
    });

    test('环比文案跟随区间称呼', () {
      final text = screenDurationDiffText(10 * 3600 * 1000, 4 * 3600 * 1000, comparedLabel: '上周');

      expect(text, '较上周增加6小时');
    });

    test('减少方向', () {
      expect(
        screenDurationDiffText(2 * 3600 * 1000, 3 * 3600 * 1000 - 1),
        contains('减少'),
      );
    });
  });

  group('dateKey 往返', () {
    test('补零后可稳定字典序比较', () {
      final jan = ScreenUsageDaily.dateKey(DateTime(2026, 1, 5));
      final sep = ScreenUsageDaily.dateKey(DateTime(2026, 9, 14));

      expect(jan, '2026-01-05');
      expect(jan.compareTo(sep), lessThan(0));
      expect(ScreenUsageDaily.parseDateKey(sep), DateTime(2026, 9, 14));
    });

    test('非法日期串返回 null 而不抛', () {
      expect(ScreenUsageDaily.parseDateKey('bad'), isNull);
      expect(ScreenUsageDaily.parseDateKey('2026-13-x'), isNull);
    });
  });
}
