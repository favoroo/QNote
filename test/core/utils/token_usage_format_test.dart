import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/token_usage_format.dart';

void main() {
  group('formatTokenCount', () {
    test('千位以下原样输出', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(999), '999');
    });

    test('千位区间用 K，且去掉多余的小数零', () {
      expect(formatTokenCount(1000), '1K');
      expect(formatTokenCount(1250), '1.3K');
      expect(formatTokenCount(12345), '12.3K');
    });

    test('十万以上不再保留小数（宽度有限）', () {
      expect(formatTokenCount(123456), '123K');
    });

    test('百万区间用 M', () {
      expect(formatTokenCount(1000000), '1M');
      expect(formatTokenCount(1234567), '1.23M');
      expect(formatTokenCount(123456789), '123M');
    });

    test('负数按 0 处理，避免出现 -1K 这种文案', () {
      expect(formatTokenCount(-5), '0');
    });
  });

  group('formatTokenCountExact', () {
    test('按三位分组加逗号', () {
      expect(formatTokenCountExact(0), '0');
      expect(formatTokenCountExact(999), '999');
      expect(formatTokenCountExact(1000), '1,000');
      expect(formatTokenCountExact(1234567), '1,234,567');
    });
  });
}
