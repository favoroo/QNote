import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_auth_service.dart';

void main() {
  group('MiFitnessAuthService.parsePassportResponse', () {
    // 取自 account.xiaomi.com/pass/serviceLoginAuth2 的真实响应体：
    // Content-Type 是 application/json，但正文带 &&&START&&& 包裹，
    // 交给 Dio 默认 JSON transformer 会在 offset 0 抛 FormatException。
    test('解析带 &&&START&&& 包裹的 passport 响应', () {
      const body = '&&&START&&&{"qs":"","code":70016,"description":"登录验证失败",'
          '"securityStatus":0,"_sign":"","sid":"miothealth","result":"error",'
          '"location":"","callback":"https://sts-hlth.io.mi.com/healthapp/sts"}';

      final map = MiFitnessAuthService.parsePassportResponse(body);

      expect(map['code'], equals(70016));
      expect(map['sid'], equals('miothealth'));
      expect(map['callback'], equals('https://sts-hlth.io.mi.com/healthapp/sts'));
    });

    test('解析扫码接口的成功响应（含尾部 &&&END&&& 与首尾空白）', () {
      const body = ' &&&START&&&{"code":0,"userId":"123456",'
          '"passToken":"pt_xxx","ssecurity":"c2VjIA==",'
          '"location":"https://sts.io.mi.com/sts?rc=&_cc=3"}&&&END&&& ';

      final map = MiFitnessAuthService.parsePassportResponse(body);

      expect(map['code'], equals(0));
      expect(map['userId'], equals('123456'));
      expect(map['ssecurity'], equals('c2VjIA=='));
    });

    test('不带包裹的裸 JSON 同样可解析', () {
      final map = MiFitnessAuthService.parsePassportResponse('{"code":0,"result":"ok"}');

      expect(map['result'], equals('ok'));
    });

    test('响应不是 JSON（如被网关劫持成 HTML 页）时抛 FormatException', () {
      expect(
        () => MiFitnessAuthService.parsePassportResponse('<html>502 Bad Gateway</html>'),
        throwsFormatException,
      );
    });

    test('空响应体抛 FormatException，而不是静默返回空 Map', () {
      expect(
        () => MiFitnessAuthService.parsePassportResponse(''),
        throwsFormatException,
      );
    });

    test('JSON 数组等非对象响应体抛 FormatException', () {
      expect(
        () => MiFitnessAuthService.parsePassportResponse('&&&START&&&[1,2,3]'),
        throwsFormatException,
      );
    });
  });
}
