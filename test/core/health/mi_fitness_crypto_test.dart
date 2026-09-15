import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/health/mi_fitness_crypto.dart';

void main() {
  group('MiFitnessCrypto', () {
    test('RC4-drop1024 加解密对称可逆验证', () {
      final key = Uint8List.fromList(utf8.encode('test-secret-key-12345678'));
      final plainText = 'Hello Mi Fitness! 小米运动健康云端同步测试 123456';
      final plainBytes = Uint8List.fromList(utf8.encode(plainText));

      final encrypted = MiFitnessCrypto.rc4Drop1024(key, plainBytes);
      expect(encrypted, isNot(equals(plainBytes)));

      final decrypted = MiFitnessCrypto.rc4Drop1024(key, encrypted);
      expect(utf8.decode(decrypted), equals(plainText));
    });

    test('generateRawNonce 生成 12 字节且后 4 字节为大端分钟时间戳', () {
      final fixedTime = DateTime.fromMillisecondsSinceEpoch(1710000000000); // 1710000000000 ms
      final rawNonce = MiFitnessCrypto.generateRawNonce(now: fixedTime);
      expect(rawNonce.length, equals(12));

      final expectedMinutes = fixedTime.millisecondsSinceEpoch ~/ 60000;
      final byteData = ByteData.sublistView(rawNonce, 8, 12);
      final minutesFromNonce = byteData.getUint32(0, Endian.big);
      expect(minutesFromNonce, equals(expectedMinutes));
    });

    test('完整请求加密与解密往返验证', () {
      // 模拟一个 32 字节的 Base64 ssecurity
      final mockSsecurity = base64.encode(List<int>.generate(32, (i) => i * 7 % 256));
      const method = 'POST';
      const path = '/app/v1/data/get_fitness_data_by_time';
      final payload = {
        'start_time': 1711929600,
        'end_time': 1712015999,
        'key': 'steps',
        'reverse': true,
      };

      final formParams = MiFitnessCrypto.encryptRequestParams(
        method: method,
        path: path,
        ssecurityB64: mockSsecurity,
        payload: payload,
      );

      expect(formParams.containsKey('data'), isTrue);
      expect(formParams.containsKey('rc4_hash__'), isTrue);
      expect(formParams.containsKey('signature'), isTrue);
      expect(formParams.containsKey('_nonce'), isTrue);

      // 模拟服务端响应：使用同样的 signedNonce 加密一个返回 JSON
      final mockResponse = {
        'code': 0,
        'message': 'ok',
        'result': {
          'data_list': [
            {'key': 'steps', 'time': 1711933200, 'value': '{"steps":100}'}
          ]
        }
      };

      final rawNonce = base64.decode(formParams['_nonce']!);
      final signedNonceBytes = MiFitnessCrypto.computeSignedNonce(mockSsecurity, rawNonce);
      final serverResponseBytes = MiFitnessCrypto.rc4Drop1024(
        signedNonceBytes,
        Uint8List.fromList(utf8.encode(json.encode(mockResponse))),
      );
      final serverResponseB64 = base64.encode(serverResponseBytes);

      final decrypted = MiFitnessCrypto.decryptResponse(
        ssecurityB64: mockSsecurity,
        nonceB64: formParams['_nonce']!,
        responseBodyText: serverResponseB64,
      );

      expect(decrypted['code'], equals(0));
      expect(decrypted['message'], equals('ok'));
      expect(decrypted['result']['data_list'][0]['key'], equals('steps'));
    });
  });
}
