import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/edge_tts_client.dart';

void main() {
  group('EdgeTtsClient.generateSecMsGecFor', () {
    test('与上游 edge-tts DRM 算法对齐（固定时间戳期望值）', () {
      // UTC 2026-09-19 04:23:04Z，期望值由同一算法在 Python 端独立计算
      final utc = DateTime.utc(2026, 9, 19, 4, 23, 4);
      expect(
        EdgeTtsClient.generateSecMsGecFor(utc),
        'F1FEBCBC5A69A5C5A5BFF0B2E470829DAD8963EE0A9D1365D48A1FCEF795E7FD',
      );
    });

    test('5 分钟边界内的时间产生相同令牌', () {
      final a = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 20, 1),
      );
      final b = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 24, 59),
      );
      expect(a, b);
    });

    test('跨 5 分钟边界令牌变化', () {
      final a = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 24, 59),
      );
      final b = EdgeTtsClient.generateSecMsGecFor(
        DateTime.utc(2026, 9, 19, 4, 25, 1),
      );
      expect(a, isNot(b));
    });
  });

  group('EdgeTtsClient.buildSsml', () {
    test('包含音色名与语速百分比', () {
      final ssml = EdgeTtsClient.buildSsml(
        text: '你好',
        voice: 'zh-CN-YunxiNeural',
        rate: 1.2,
      );
      expect(ssml, contains("<voice name='zh-CN-YunxiNeural'>"));
      expect(ssml, contains("rate='+20%'"));
      expect(ssml, contains('你好'));
    });

    test('语速倍率换算为百分比偏移', () {
      String rateOf(double multiplier) {
        final ssml = EdgeTtsClient.buildSsml(
          text: 'x',
          voice: 'v',
          rate: multiplier,
        );
        return RegExp(r"rate='([^']+)'").firstMatch(ssml)!.group(1)!;
      }

      expect(rateOf(1.0), '+0%');
      expect(rateOf(0.8), '-20%');
      expect(rateOf(1.05), '+5%');
    });

    test('XML 特殊字符转义', () {
      final ssml = EdgeTtsClient.buildSsml(
        text: 'a&b<c>"d\'e',
        voice: 'v',
        rate: 1.0,
      );
      expect(ssml, contains('a&amp;b&lt;c&gt;&quot;d&apos;e'));
      expect(ssml, isNot(contains('a&b')));
    });
  });
}
