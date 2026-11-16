import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/diet_nutrition.dart';

void main() {
  group('normalizeDietCalories', () {
    test('接受数字与带单位字符串，并取整', () {
      expect(normalizeDietCalories(620), 620);
      expect(normalizeDietCalories(620.4), 620);
      expect(normalizeDietCalories('620kcal'), 620);
      expect(normalizeDietCalories('约620千卡'), 620);
      expect(normalizeDietCalories('1,200 kcal'), 1200);
      // 优先取带 kcal/千卡 单位的数字，避免把「每100g」误当热量
      expect(normalizeDietCalories('每100g 536千卡，一包70g'), 536);
      expect(normalizeDietCalories('两份，共620千卡'), 620);
      expect(normalizeDietCalories('米饭2碗共620'), 620);
    });

    test('0、负数、无法解析与超限值返回 null', () {
      expect(normalizeDietCalories(0), isNull);
      expect(normalizeDietCalories(-5), isNull);
      expect(normalizeDietCalories('约'), isNull);
      expect(normalizeDietCalories(double.nan), isNull);
      expect(normalizeDietCalories(maxMealCalories + 1), isNull);
      // 先整体解析再退化到提取数字，避免 1e9 被截成 1 误判为合法
      expect(normalizeDietCalories('1e9'), isNull);
    });
  });
}
