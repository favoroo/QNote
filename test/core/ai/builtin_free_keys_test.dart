import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';

void main() {
  group('BuiltinFreeKeys & FreeModelKeyManager Tests', () {
    test('4个内置密钥解密后与预期一致且不为空', () {
      final keys = BuiltinFreeKeys.getDecryptedKeys();
      expect(keys.length, equals(4));

      expect(keys[0], equals('sk-6yNu82SrnSc8nA5c3j1oFScGII7SxtNi'));
      expect(keys[1], equals('sk-IWpKaapIDrNvFpzkuXV16s4TWw4xCN28'));
      expect(keys[2], equals('sk-uo37IQgAueHyylHrrY57eouDYrsrBvg3'));
      expect(keys[3], equals('sk-Z76tPV1WnunUP7I1ZWbtRouHrlqKSpsW'));

      for (final k in keys) {
        expect(k.startsWith('sk-'), isTrue);
        expect(k.length, equals(35));
      }
    });

    test('FreeModelKeyManager 顺位轮询 Round-Robin 正常工作', () {
      final manager = FreeModelKeyManager.instance;
      final k1 = manager.acquireNextKey();
      final k2 = manager.acquireNextKey();
      final k3 = manager.acquireNextKey();
      final k4 = manager.acquireNextKey();
      final k5 = manager.acquireNextKey();

      expect({k1, k2, k3, k4}.length, equals(4));
      expect(k5, equals(k1)); // 循环回第 1 个
    });

    test('FreeModelKeyManager 限速自动切 Key 故障转移', () {
      final manager = FreeModelKeyManager.instance;
      final current = manager.acquireNextKey();
      final nextKey = manager.rotateKeyOnFailure(current);

      expect(nextKey, isNot(equals(current)));
      expect(nextKey.startsWith('sk-'), isTrue);
    });

    test('isRecoverableError 能够正确识别商汤 400 限频、429、5xx 及网络超时错误', () {
      final manager = FreeModelKeyManager.instance;

      // 1. 常见 HTTP 状态码
      for (final code in [400, 401, 403, 408, 429, 500, 502, 503, 504]) {
        final err = DioException(
          requestOptions: RequestOptions(path: '/chat'),
          response: Response(
            requestOptions: RequestOptions(path: '/chat'),
            statusCode: code,
          ),
        );
        expect(manager.isRecoverableError(err), isTrue, reason: 'Status code $code 应该被判定为可恢复');
      }

      // 2. 网络抖动与超时
      final timeoutErr = DioException(
        requestOptions: RequestOptions(path: '/chat'),
        type: DioExceptionType.connectionTimeout,
      );
      expect(manager.isRecoverableError(timeoutErr), isTrue);

      final connectionErr = DioException(
        requestOptions: RequestOptions(path: '/chat'),
        type: DioExceptionType.connectionError,
      );
      expect(manager.isRecoverableError(connectionErr), isTrue);

      // 3. 关键字判定
      final keywordErr = Exception('SenseNova: requests_rate_limit: free concurrency limit reached');
      expect(manager.isRecoverableError(keywordErr), isTrue);

      final chineseKeywordErr = Exception('调用失败：模型当前并发超限或配额不足，请稍后重试');
      expect(manager.isRecoverableError(chineseKeywordErr), isTrue);

      // 4. 不可恢复错误（例如客户端非法参数 422、405 等无任何限频特征的错误）
      final nonRecoverable = DioException(
        requestOptions: RequestOptions(path: '/chat'),
        response: Response(
          requestOptions: RequestOptions(path: '/chat'),
          statusCode: 422,
        ),
      );
      expect(manager.isRecoverableError(nonRecoverable), isFalse);
    });

    test('getBackoffDelay 阶梯式指数增长并附带合理随机扰动', () {
      final manager = FreeModelKeyManager.instance;

      final d1 = manager.getBackoffDelay(1);
      final d2 = manager.getBackoffDelay(2);
      final d3 = manager.getBackoffDelay(3);

      expect(d1.inMilliseconds, greaterThanOrEqualTo(300));
      expect(d1.inMilliseconds, lessThan(450 + 50));

      expect(d2.inMilliseconds, greaterThanOrEqualTo(600));
      expect(d2.inMilliseconds, lessThan(750 + 50));

      expect(d3.inMilliseconds, greaterThanOrEqualTo(1200));
      expect(d3.inMilliseconds, lessThan(1350 + 50));
    });
  });
}
