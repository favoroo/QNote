import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/health_step_trend.dart';

Map<DateTime, int> _steps(Map<int, int> dayToSteps, {int month = 3, int year = 2026}) {
  return {
    for (final entry in dayToSteps.entries) DateTime(year, month, entry.key): entry.value,
  };
}

void main() {
  group('buildStepTrend 粒度选择', () {
    test('周区间按天出柱，缺数据的日期保留为空桶', () {
      final trend = buildStepTrend(
        startDate: DateTime(2026, 3, 10),
        endDate: DateTime(2026, 3, 18),
        stepsByDay: _steps({10: 5000, 12: 9000}),
      );

      expect(trend.unit, StepTrendUnit.day);
      expect(trend.buckets.length, 9);
      expect(trend.buckets.first.value, 5000);
      expect(trend.buckets.first.axisLabel, '3/10');
      expect(trend.buckets[1].hasData, isFalse);
      expect(trend.buckets[1].value, 0);
    });

    test('月区间仍按天出柱', () {
      final trend = buildStepTrend(
        startDate: DateTime(2026, 2, 1),
        endDate: DateTime(2026, 3, 4),
        stepsByDay: _steps({1: 8000}, month: 2),
      );

      expect(trend.unit, StepTrendUnit.day);
      expect(trend.buckets.length, 32);
    });

    test('年区间改为按月汇总，柱高取月内日均步数', () {
      final trend = buildStepTrend(
        startDate: DateTime(2025, 9, 24),
        endDate: DateTime(2026, 9, 25),
        stepsByDay: {
          DateTime(2025, 9, 24): 4000,
          DateTime(2025, 9, 25): 8000,
          DateTime(2026, 3, 5): 10000,
          DateTime(2026, 3, 6): 20000,
        },
      );

      expect(trend.unit, StepTrendUnit.month);
      expect(trend.buckets.length, 13);
      // 首桶与跨年的 1 月要带年份，其余只写月份
      expect(trend.buckets.first.axisLabel, '25年9月');
      expect(trend.buckets[4].axisLabel, '26年1月');
      expect(trend.buckets[6].axisLabel, '3月');
      expect(trend.buckets.first.rangeLabel, '2025/9/24–9/30');
      // 9 月只有区间内的两天有数据，日均 (4000+8000)/2
      expect(trend.buckets.first.value, 6000);
      // 3 月日均 (10000+20000)/2
      expect(trend.buckets[6].value, 15000);
      // 中间没有同步的月份保持空桶
      expect(trend.buckets[2].hasData, isFalse);
    });

    test('区间外的日期不参与汇总', () {
      final trend = buildStepTrend(
        startDate: DateTime(2025, 1, 20),
        endDate: DateTime(2025, 6, 10),
        stepsByDay: {
          DateTime(2025, 1, 10): 99999, // 区间开始之前
          DateTime(2025, 1, 25): 6000,
          DateTime(2025, 7, 2): 88888, // 区间结束之后
        },
      );

      expect(trend.buckets.first.value, 6000);
      expect(trend.buckets.last.hasData, isFalse);
    });
  });

  group('stepAxisLabelInterval', () {
    test('宽度足够时每个桶都给标签', () {
      expect(
        stepAxisLabelInterval(bucketCount: 9, plotWidth: 300, minLabelWidth: 30),
        1,
      );
    });

    test('宽度不足时按可容纳的标签数抽稀', () {
      // 300px 只放得下 10 个标签，32 个桶则每 4 个出一个
      expect(
        stepAxisLabelInterval(bucketCount: 32, plotWidth: 300, minLabelWidth: 30),
        4,
      );
    });

    test('单桶或异常宽度不抽稀', () {
      expect(stepAxisLabelInterval(bucketCount: 1, plotWidth: 300, minLabelWidth: 30), 1);
      expect(stepAxisLabelInterval(bucketCount: 30, plotWidth: 0, minLabelWidth: 30), 1);
    });
  });
}
