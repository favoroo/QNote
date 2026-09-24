import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/models/free_model_config.dart';

void main() {
  group('BuiltinFreeKeys & FreeModelKeyManager Tests', () {
    test('9把内置密钥解密后与预期一致且不为空', () {
      final keys = BuiltinFreeKeys.getDecryptedKeys();
      expect(keys.length, equals(9));

      expect(keys[0], equals('sk-6yNu82SrnSc8nA5c3j1oFScGII7SxtNi'));
      expect(keys[1], equals('sk-IWpKaapIDrNvFpzkuXV16s4TWw4xCN28'));
      expect(keys[2], equals('sk-uo37IQgAueHyylHrrY57eouDYrsrBvg3'));
      expect(keys[3], equals('sk-Z76tPV1WnunUP7I1ZWbtRouHrlqKSpsW'));
      expect(keys[4], equals('sk-pRerR8UvleEBomuwFoZrmHmBOK7bEw56'));
      expect(keys[5], equals('sk-rrBchwt92I6IPi8o5SOLaVnmTWQZDRs7'));
      expect(keys[6], equals('sk-PgxHbOMsG2tby9jZaguZR2GCjR685Kvi'));
      expect(keys[7], equals('sk-nftg2abzUzSlo25uCsP2AWdESdUasDwZ'));
      expect(keys[8], equals('sk-ZjAchn1pVwbTERL4tERq3cwcwJlU42uH'));

      for (final k in keys) {
        expect(k.startsWith('sk-'), isTrue);
        expect(k.length, equals(35));
      }
      // 池里不能出现重复 Key，否则轮询等于少一把
      expect(keys.toSet().length, equals(keys.length));
    });

    test('轮换预算跟随池容量，并受 maxKeyRotationAttempts 护栏封顶', () {
      final manager = FreeModelKeyManager.instance;
      // 当前 9 把 < 12 护栏：按池容量逐把扫，换 Key 只有一次往返、没必要中途收手
      expect(
        manager.keyRotationAttempts,
        equals(manager.totalKeysCount),
        reason: '池未超护栏时预算等于池容量',
      );
      expect(
        FreeModelKeyManager.maxKeyRotationAttempts,
        greaterThan(manager.totalKeysCount),
      );
    });

    test('CPA 网关内置密钥解密正确，指向 CPA 端点的模型取该 Key', () {
      // 密钥名沿用历史 Gemini 称呼。Gemini 与 Claude 内置模型先后下线后，
      // 已无内置模型走 CPA 通道，这里锁住「端点家族 → 该 Key」的判定仍然生效
      final geminiKey = BuiltinFreeKeys.getGeminiApiKey();
      expect(geminiKey, equals('sk-hq13789130001'));

      const cpaModel = FreeModelConfig(
        id: 'sample-cpa-model',
        displayName: 'Sample CPA Model',
        provider: 'openai',
        baseUrl: BuiltinFreeKeys.defaultTailscaleBaseUrl,
        modelName: 'sample-cpa-model',
        obfuscatedApiKey: 'plain-but-unused',
      );
      expect(
        FreeModelService.instance.toAiConfig(cpaModel).apiKey,
        equals(geminiKey),
        reason: '端点属于 CPA 家族时必须取那把专用 Key',
      );
    });

    test('FreeModelKeyManager 顺位轮询 Round-Robin 正常工作', () {
      final manager = FreeModelKeyManager.instance;
      final pool = BuiltinFreeKeys.getDecryptedKeys();

      // 取满一轮：应无重复地覆盖整池，再多取一把则回到本轮起点。
      // 本用例必须排在故障转移用例之前 —— 那会把一把 Key 置入 1 分钟冷却并被跳过
      final round = List<String>.generate(pool.length, (_) => manager.acquireNextKey());
      expect(round.every(pool.contains), isTrue);
      expect(round.toSet().length, equals(pool.length), reason: '一轮内不得重复取同一把');
      expect(manager.acquireNextKey(), equals(round.first));
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

    test('isKeyScopedError 只把「换 Key 就能解决」的错误判为可立即重试', () {
      final manager = FreeModelKeyManager.instance;

      DioException withStatus(int code) => DioException(
            requestOptions: RequestOptions(path: '/chat'),
            response: Response(
              requestOptions: RequestOptions(path: '/chat'),
              statusCode: code,
            ),
          );

      // 配额类：换一把 Key 就是独立额度，应立即重试而非退避
      expect(manager.isKeyScopedError(withStatus(429)), isTrue);
      expect(manager.isKeyScopedError(withStatus(401)), isTrue);
      // 商汤常以 400 + 文案回限流，也要判为准
      expect(
        manager.isKeyScopedError(
          Exception('SenseNova: RateLimitExceeded.EndpointTPMExceeded'),
        ),
        isTrue,
      );
      expect(
        manager.isKeyScopedError(Exception('调用失败：模型当前并发超限或配额不足，请稍后重试')),
        isTrue,
      );

      // 端点侧故障（5xx、连接超时）换 Key 无意义，仍需退避；非法参数两种都不算
      expect(manager.isKeyScopedError(withStatus(503)), isFalse);
      expect(
        manager.isKeyScopedError(
          DioException(
            requestOptions: RequestOptions(path: '/chat'),
            type: DioExceptionType.connectionTimeout,
          ),
        ),
        isFalse,
      );
      expect(manager.isKeyScopedError(Exception('unknown provider for model')), isFalse);
      expect(manager.isKeyScopedError(null), isFalse);
    });

    test('getQuotaRotationDelay 远短于通用指数退避', () {
      final manager = FreeModelKeyManager.instance;
      final quotaDelay = manager.getQuotaRotationDelay();
      expect(quotaDelay.inMilliseconds, greaterThanOrEqualTo(40));
      expect(quotaDelay.inMilliseconds, lessThan(40 + 80));
      // 同一失败次数下，通用退避至少是它的 4 倍起步（第 1 次 300ms+）
      expect(
        manager.getBackoffDelay(1).inMilliseconds,
        greaterThan(quotaDelay.inMilliseconds * 2),
      );
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

    test('商汤网关内置模型（含 deepseek-flash）取 Key 走整池轮询而非固定单 Key', () {
      // 回归保护：`toAiConfig` 的 isSenseNovaBuiltinKey 曾按模型 id 逐个点名，
      // DeepSeek 换名（deepseek-v4-flash → deepseek-flash）后会静默退化成
      // 清单里的固定 Key、丢掉轮询（商汤网关几乎每把 Key 都会撞 TPM）。
      final pool = BuiltinFreeKeys.getDecryptedKeys().toSet();

      final deepSeek = BuiltinFreeKeys.createDeepSeekConfig();
      expect(deepSeek.id, 'deepseek-flash');
      expect(deepSeek.modelName, 'deepseek-flash');
      expect(deepSeek.displayName, 'DeepSeek Flash');
      expect(deepSeek.baseUrl, 'https://token.sensenova.cn/v1');

      // 连续构造 8 次：全部落在整池 Key 内，且不是一把定死的 Key
      // （前面的故障转移用例会把某把 Key 置入 1 分钟冷却，故不断言 8 把互不相同）
      final picked = List<String>.generate(
        8,
        (_) => FreeModelService.instance.toAiConfig(deepSeek).apiKey,
      );
      expect(
        picked.every(pool.contains),
        isTrue,
        reason: '商汤网关下的内置模型必须取自整池轮询 Key',
      );
      expect(
        picked.toSet().length,
        greaterThan(1),
        reason: '必须轮换，不能固化成配置里那把 Key',
      );
    });

    test('整池冷却后 hasAvailableKey 转 false，acquireNextKey 仍兜底给出一把', () {
      // 必须排在最后：会把整池置入 1 分钟冷却，污染前面的轮询与预算断言
      final manager = FreeModelKeyManager.instance;
      final pool = BuiltinFreeKeys.getDecryptedKeys();

      expect(manager.hasAvailableKey(), isTrue);
      expect(manager.availableKeyCount, greaterThan(0));

      for (final key in pool) {
        manager.rotateKeyOnFailure(key);
      }
      expect(manager.hasAvailableKey(), isFalse);
      expect(manager.availableKeyCount, equals(0));

      // 全冷却也不能抛异常或返回空串：宁可再撞一次 429，也不能让请求发不出去
      final fallback = manager.acquireNextKey();
      expect(fallback, isNotEmpty);
      expect(pool.contains(fallback), isTrue);
    });
  });
}
