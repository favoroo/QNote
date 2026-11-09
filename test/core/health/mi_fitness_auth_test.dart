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

  group('MiFitnessAuthService.findCookie', () {
    test('按完整名字取值，不会被 miothealth_serviceToken 抢先命中', () {
      final headers = ['miothealth_serviceToken=health_token; Path=/; HttpOnly'];

      expect(
        MiFitnessAuthService.findCookie(headers, 'miothealth_serviceToken'),
        equals('health_token'),
      );
      expect(MiFitnessAuthService.findCookie(headers, 'serviceToken'), isNull);
    });

    test('同一响应里多个 cookie 各取各的', () {
      final headers = [
        'cUserId=abc; Path=/',
        'passToken=V1:tok; Path=/; Domain=.xiaomi.com',
      ];

      expect(MiFitnessAuthService.findCookie(headers, 'cUserId'), equals('abc'));
      expect(MiFitnessAuthService.findCookie(headers, 'passToken'), equals('V1:tok'));
      expect(MiFitnessAuthService.findCookie(headers, 'userId'), isNull);
    });

    test('名字只是前缀的 cookie 不会误命中', () {
      expect(MiFitnessAuthService.findCookie(['userId_x=1; Path=/'], 'userId'), isNull);
    });
  });

  group('MiFitnessAuthService.parseExtensionPragma', () {
    test('解析 pragma 里的 ssecurity 与 nonce', () {
      final pragma = MiFitnessAuthService.parseExtensionPragma(
        ['{"ssecurity":"c2Vj","nonce":1234567890}'],
      );

      expect(pragma['ssecurity'], equals('c2Vj'));
      expect(pragma['nonce'], equals(1234567890));
    });

    test('缺失、空列表或非 JSON 一律回空 Map，不抛异常', () {
      expect(MiFitnessAuthService.parseExtensionPragma(null), isEmpty);
      expect(MiFitnessAuthService.parseExtensionPragma([]), isEmpty);
      expect(MiFitnessAuthService.parseExtensionPragma(['<html>']), isEmpty);
    });
  });

  group('MiFitnessAuthService.parsePassportLogin', () {
    test('JSON 字段齐全时直接取用', () {
      final login = MiFitnessAuthService.parsePassportLogin({
        'code': 0,
        'securityStatus': 0,
        'userId': '123456',
        'cUserId': 'cu_1',
        'passToken': 'pt_1',
        'ssecurity': 'c2Vj',
        'nonce': 999,
        'location': 'https://sts.io.mi.com/sts?sign=x',
      });

      expect(login.code, equals(0));
      expect(login.userId, equals('123456'));
      expect(login.cUserId, equals('cu_1'));
      expect(login.passToken, equals('pt_1'));
      expect(login.ssecurity, equals('c2Vj'));
      expect(login.nonce, equals(999));
      expect(login.hasStsInputs, isTrue);
    });

    test('轮换后的 passToken/cUserId 只走 Set-Cookie 时也能读到', () {
      final login = MiFitnessAuthService.parsePassportLogin(
        {
          'code': 0,
          'userId': '123456',
          'ssecurity': 'c2Vj',
          'nonce': 1,
          'location': 'https://sts.io.mi.com/sts',
        },
        setCookieHeaders: ['passToken=pt_rotated; Path=/', 'cUserId=cu_new; Path=/'],
        known: MiAuthCredentials(
          userId: '123456',
          serviceToken: 'old',
          ssecurity: 'c2Vj',
          cUserId: 'cu_old',
          passToken: 'pt_old',
          expireTime: DateTime.now(),
        ),
      );

      expect(login.passToken, equals('pt_rotated'));
      expect(login.cUserId, equals('cu_new'));
    });

    test('响应缺字段时回退到本地已有值（不把凭据写空）', () {
      final login = MiFitnessAuthService.parsePassportLogin(
        {'code': 0},
        known: MiAuthCredentials(
          userId: '123456',
          serviceToken: 'st',
          ssecurity: 'ssec',
          cUserId: 'cu',
          passToken: 'pt',
          expireTime: DateTime.now(),
        ),
      );

      expect(login.userId, equals('123456'));
      expect(login.passToken, equals('pt'));
      expect(login.cUserId, equals('cu'));
      // ssecurity/nonce 不来自 known，缺了就该判成响应不完整
      expect(login.hasStsInputs, isFalse);
    });

    test('ssecurity/nonce 走 Extension-Pragma 兜底', () {
      final login = MiFitnessAuthService.parsePassportLogin(
        {
          'code': 0,
          'userId': '1',
          'passToken': 'pt',
          'cUserId': 'cu',
          'location': 'https://sts.io.mi.com/sts',
        },
        pragma: {'ssecurity': 'c2Vj', 'nonce': 42},
      );

      expect(login.ssecurity, equals('c2Vj'));
      expect(login.nonce, equals(42));
      expect(login.hasStsInputs, isTrue);
    });

    test('透传 code 与 securityStatus 供上层分级处理', () {
      final rejected = MiFitnessAuthService.parsePassportLogin({'code': 70016});
      expect(rejected.code, equals(70016));
      expect(rejected.securityStatus, equals(0));

      final confirm = MiFitnessAuthService.parsePassportLogin({'code': 0, 'securityStatus': 1});
      expect(confirm.securityStatus, equals(1));
    });
  });
}
