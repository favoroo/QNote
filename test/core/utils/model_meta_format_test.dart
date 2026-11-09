import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/model_meta_format.dart';

/// 模型元数据展示文案：倍率与上下文窗口
void main() {
  test('倍率：整数不带小数，缺信息返回 null', () {
    expect(formatRate(1), '1×');
    expect(formatRate(0), '0×');
    expect(formatRate(0.25), '0.25×');
    expect(formatRate(6.5), '6.5×');
    expect(formatRate(null), isNull);
  });

  test('上下文窗口：M / K 档位，缺信息返回 null', () {
    expect(formatContextWindow(1000000), '1M');
    expect(formatContextWindow(1048576), '1M');
    expect(formatContextWindow(256000), '256K');
    expect(formatContextWindow(63999), '64K');
    expect(formatContextWindow(8192), '8K');
    expect(formatContextWindow(512), '512');
    expect(formatContextWindow(0), isNull);
    expect(formatContextWindow(null), isNull);
  });
}
