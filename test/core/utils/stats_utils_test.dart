import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';

/// 屏幕时长趋势柱的 Y 轴上限：日粒度再 clamp 到 24 小时
double _axisCeiling(double maxHours) => niceHourCeiling(maxHours * 1.25).clamp(2.0, 24.0);

void main() {
  group('niceHourCeiling', () {
    test('抬到便于阅读的整点小时刻度', () {
      expect(niceHourCeiling(0), 2);
      expect(niceHourCeiling(0.5), 2);
      expect(niceHourCeiling(4.75), 6);
      expect(niceHourCeiling(9.125), 12);
      expect(niceHourCeiling(23.75), 24);
      expect(niceHourCeiling(28.125), 32);
      // 超出刻度表后按 10 小时向上取整
      expect(niceHourCeiling(35), 40);
    });

    test('上限恒不低于当日最大值，柱子不会溢出绘图区', () {
      for (double maxHours = 0; maxHours <= 24; maxHours += 0.25) {
        expect(
          _axisCeiling(maxHours),
          greaterThanOrEqualTo(maxHours),
          reason: '单日 $maxHours 小时时上限被截到了 ${_axisCeiling(maxHours)}',
        );
      }
    });

    test('留白适度，柱子不会被压得太矮', () {
      for (double maxHours = 0.5; maxHours <= 24; maxHours += 0.5) {
        expect(
          _axisCeiling(maxHours),
          lessThanOrEqualTo(maxHours * 2 + 2),
          reason: '单日 $maxHours 小时时上限 ${_axisCeiling(maxHours)} 留白过多',
        );
      }
    });

    test('刻度为偶数，右侧 Y 轴标签落在整数小时上', () {
      for (final maxHours in [0.0, 1.5, 7.7, 12.5, 19.0, 23.9, 30.0]) {
        final ceiling = _axisCeiling(maxHours);
        expect(ceiling % 2, 0, reason: '上限 $ceiling 应为偶数');
        expect((ceiling / 2) % 1, 0, reason: '中间刻度 ${ceiling / 2} 应为整数小时');
      }
    });

    test('典型一天 7小时42分：上限 12 小时，柱占约三分之二', () {
      final ceiling = _axisCeiling(7 + 42 / 60.0);
      expect(ceiling, 12);
      expect(7.7 / ceiling, greaterThan(0.5));
      expect(7.7 / ceiling, lessThan(1));
    });
  });
}
