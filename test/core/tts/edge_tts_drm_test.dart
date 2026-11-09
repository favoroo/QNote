import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/edge_tts_drm.dart';

/// 期望值全部由上游 `edge-tts 7.3.1` 的 `drm.generate_sec_ms_gec_v2` 在同一批
/// 固定时间戳上独立算出（Python 端），用于锁死 Dart 移植的逐位一致性。
void main() {
  group('EdgeTtsDrm 令牌（v2 算法 golden）', () {
    test('待摘要字符串为「100ns 时间戳 + 可信令牌」', () {
      expect(
        EdgeTtsDrm.hashInputForUnixSeconds(1794000000),
        '1343847360000000006A5AA1D4EAFF4E9FB37E23D68491D6F4',
      );
      expect(
        EdgeTtsDrm.hashInputForUnixSeconds(0),
        '1164447360000000006A5AA1D4EAFF4E9FB37E23D68491D6F4',
      );
      expect(
        EdgeTtsDrm.hashInputForUnixSeconds(1000000000),
        '1264447350000000006A5AA1D4EAFF4E9FB37E23D68491D6F4',
      );
    });

    test('完整令牌与上游 7.3.1 输出一致', () {
      final cases = <(double, String)>[
        (
          1794000000,
          '6EA6AF6A0550F520-'
              '17E5A544A1EFE811EA5248AFBD9780637964201A6D3A15ADE53A30AB9D066A4F',
        ),
        (
          1794000300,
          'A505F84E676D6B42-'
              'A00A7D7A97CD500B2AB5E83C82B9523CD40375ABE5D44320C04F19C119C9DAC8',
        ),
        (
          0,
          '52BC7A17B50DFEC9-'
              '28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6',
        ),
        (
          1000000000,
          '5E9153719FADA922-'
              '14D2A75113EC5862E17303287DCDB197E3A671DF9FCC53C100D6B27928384B98',
        ),
      ];
      for (final (unix, token) in cases) {
        expect(
          EdgeTtsDrm.generateSecMsGecForUnixSeconds(unix),
          token,
          reason: 'unix=$unix',
        );
      }
    });

    test('令牌两段各自与上游中间量一致（CS64 小端展开 / SHA256 大端展开）', () {
      const input = '1343847360000000006A5AA1D4EAFF4E9FB37E23D68491D6F4';
      expect(EdgeTtsDrm.cs64PartForInput(input), '6EA6AF6A0550F520');
      expect(
        EdgeTtsDrm.sha256PartForInput(input),
        '17E5A544A1EFE811EA5248AFBD9780637964201A6D3A15ADE53A30AB9D066A4F',
      );
    });

    test('同一 5 分钟桶内令牌相同，跨桶变化', () {
      final a = EdgeTtsDrm.generateSecMsGecForUnixSeconds(1794000000);
      final b = EdgeTtsDrm.generateSecMsGecForUnixSeconds(1794000299);
      final c = EdgeTtsDrm.generateSecMsGecForUnixSeconds(1794000300);
      expect(b, a);
      expect(c, isNot(a));
    });

    test('令牌形如 <16位hex>-<64位hex>', () {
      final token = EdgeTtsDrm.generateSecMsGec();
      expect(token, matches(RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$')));
    });

    test('URL 版本标签为 v2 前缀', () {
      expect(EdgeTtsDrm.secMsGecVersion, '2-143.0.3650.75');
    });
  });
}
