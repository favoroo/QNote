import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/sensenova_quota_policy.dart';

/// 商汤网关限流策略层单测：全部是纯函数与「读错误体」的流处理，不联网。
void main() {
  // 策略阈值现在是可下发的可变静态量（见 SensenovaQuotaPolicy.apply），
  // 没有这行重置，一条用例下发的值会泄漏到下一条，表现为「单独跑通、全量跑挂」。
  setUp(SensenovaQuotaPolicy.resetToDefaults);

  /// 构造一个带响应体的 badResponse 异常（流式路径下 data 是未消费的 ResponseBody）
  DioException badResponse({required int statusCode, Object? data}) {
    final options = RequestOptions(path: '/chat/completions');
    return DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: statusCode,
        data: data,
      ),
    );
  }

  group('SensenovaQuotaPolicy.classify', () {
    test('实测的两条真实 429 响应体各自归对形态', () {
      // 2026-09-25 直连抓到的原文
      const tpmBody = '{"error":{"message":"inference exceeds tpm/rpm limit",'
          '"type":"rate_limit_error","code":"RateLimitExceeded.EndpointTPMExceeded"}}';
      const rpsBody = '{"error":{"message":"rps exhausted",'
          '"type":"quota_exceeded_error","code":"8"}}';

      expect(
        SensenovaQuotaPolicy.classify(statusCode: 429, bodyText: tpmBody),
        equals(QuotaSignal.tpm),
      );
      expect(
        SensenovaQuotaPolicy.classify(statusCode: 429, bodyText: rpsBody),
        equals(QuotaSignal.rpsBurst),
      );
    });

    test('rps 判定优先于 TPM（两者都是 429，处置却相反）', () {
      final signal = SensenovaQuotaPolicy.classify(
        statusCode: 429,
        bodyText: 'inference exceeds tpm/rpm limit; rps exhausted',
      );
      expect(signal, equals(QuotaSignal.rpsBurst));
    });

    test('读不到 body 的 429 保守按 TPM 额度处理', () {
      expect(
        SensenovaQuotaPolicy.classify(statusCode: 429),
        equals(QuotaSignal.tpm),
      );
    });

    test('401/403 归 auth、5xx 归 server、其余归 none', () {
      expect(SensenovaQuotaPolicy.classify(statusCode: 401), equals(QuotaSignal.auth));
      expect(SensenovaQuotaPolicy.classify(statusCode: 403), equals(QuotaSignal.auth));
      expect(SensenovaQuotaPolicy.classify(statusCode: 502), equals(QuotaSignal.server));
      expect(SensenovaQuotaPolicy.classify(statusCode: 400), equals(QuotaSignal.none));
    });

    test('HTTP 200 配上一段含 tpm 字样的正文不算限流', () {
      // 模型把服务商报错文本原样复述给用户是常态，判成限流会引发无意义重试风暴
      final signal = SensenovaQuotaPolicy.classify(
        statusCode: 200,
        bodyText: '这个错误提示是 inference exceeds tpm/rpm limit',
      );
      expect(signal, equals(QuotaSignal.none));
    });

    test('状态码为 null（SSE 带内错误）时只按正文判定', () {
      expect(
        SensenovaQuotaPolicy.classify(bodyText: '{"error":{"code":"8","message":"rps exhausted"}}'),
        equals(QuotaSignal.rpsBurst),
      );
      expect(
        SensenovaQuotaPolicy.classify(bodyText: 'RateLimitExceeded.EndpointTPMExceeded'),
        equals(QuotaSignal.tpm),
      );
      expect(SensenovaQuotaPolicy.classify(bodyText: '一切正常'), equals(QuotaSignal.none));
    });

    test('正文里的 token 数字不被误判成状态码或额度', () {
      final signal = SensenovaQuotaPolicy.classify(
        statusCode: 400,
        bodyText: '{"error":{"message":"too large","usage":{"prompt_tokens":400429}}}',
      );
      expect(signal, equals(QuotaSignal.none));
    });
  });

  group('SensenovaQuotaPolicy.keyCooldown', () {
    test('rps 冷却远短于 TPM，且只有配额/鉴权才冷却', () {
      expect(
        SensenovaQuotaPolicy.keyCooldown(QuotaSignal.rpsBurst) <
            SensenovaQuotaPolicy.keyCooldown(QuotaSignal.tpm),
        isTrue,
        reason: '一次 rps 突发就把健康 Key 关一分钟是原机制最大的自伤点',
      );
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.rpsBurst).inSeconds, equals(2));
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.tpm).inSeconds, equals(60));
      expect(
        SensenovaQuotaPolicy.keyCooldown(QuotaSignal.auth),
        equals(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.tpm)),
      );
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.server), equals(Duration.zero));
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.none), equals(Duration.zero));
    });
  });

  group('SensenovaQuotaPolicy.rotationDelay', () {
    test('rps 等待下界跨过实测 0.6 秒突发窗口', () {
      for (var i = 0; i < 20; i++) {
        final ms = SensenovaQuotaPolicy.rotationDelay(QuotaSignal.rpsBurst, 1).inMilliseconds;
        expect(ms, inInclusiveRange(350, 649));
      }
    });

    test('TPM 比 rps 快、鉴权最快（换一把就有新 Key，不必等回填）', () {
      for (var i = 0; i < 20; i++) {
        final tpmMs = SensenovaQuotaPolicy.rotationDelay(QuotaSignal.tpm, 1).inMilliseconds;
        final authMs = SensenovaQuotaPolicy.rotationDelay(QuotaSignal.auth, 1).inMilliseconds;
        expect(tpmMs, inInclusiveRange(150, 349));
        expect(authMs, inInclusiveRange(60, 119));
        expect(authMs < tpmMs, isTrue);
      }
    });

    test('server 退避随尝试次数增长但不失控，none 不等待', () {
      final first = SensenovaQuotaPolicy.rotationDelay(QuotaSignal.server, 1).inMilliseconds;
      final last = SensenovaQuotaPolicy.rotationDelay(QuotaSignal.server, 4).inMilliseconds;
      expect(last > first, isTrue);
      expect(SensenovaQuotaPolicy.rotationDelay(QuotaSignal.server, 99).inMilliseconds,
          lessThan(3000));
      expect(SensenovaQuotaPolicy.rotationDelay(QuotaSignal.none, 1), equals(Duration.zero));
    });

    test('整池尝试的最坏等待仍小于一次提问的可接受延迟', () {
      // 4 把 Key × TPM 节奏：等待总和要远小于 maxQuotaHold，否则排队语义形同虚设
      var totalMs = 0;
      for (var attempt = 1; attempt <= SensenovaQuotaPolicy.poolMaxAttempts; attempt++) {
        totalMs += SensenovaQuotaPolicy.rotationDelay(QuotaSignal.tpm, attempt).inMilliseconds;
      }
      expect(totalMs, lessThan(SensenovaQuotaPolicy.maxQuotaHold.inMilliseconds ~/ 2));
    });
  });

  group('SensenovaQuotaPolicy.readErrorBody', () {
    test('流式 429 的未消费响应体可以读出来', () async {
      const body = '{"error":{"message":"rps exhausted","code":"8"}}';
      final error = badResponse(
        statusCode: 429,
        data: ResponseBody.fromString(body, 429),
      );

      final text = await SensenovaQuotaPolicy.readErrorBody(error);
      expect(text, contains('rps exhausted'));
      expect(
        SensenovaQuotaPolicy.classify(statusCode: 429, bodyText: text),
        equals(QuotaSignal.rpsBurst),
      );
    });

    test('同一异常第二次读安全返回 null（单订阅流）', () async {
      final error = badResponse(
        statusCode: 429,
        data: ResponseBody.fromString('inference exceeds tpm/rpm limit', 429),
      );

      expect(await SensenovaQuotaPolicy.readErrorBody(error), isNotNull);
      expect(await SensenovaQuotaPolicy.readErrorBody(error), isNull);
    });

    test('流永不产出时在预算内返回 null，不卡住重试', () async {
      final controller = StreamController<Uint8List>();
      addTearDown(controller.close);
      final error = badResponse(
        statusCode: 429,
        data: ResponseBody(controller.stream, 429),
      );

      final text = await SensenovaQuotaPolicy.readErrorBody(
        error,
        budget: const Duration(milliseconds: 30),
      );
      expect(text, isNull);
    });

    test('非流式路径（data 已是 Map/String）直接文本化', () async {
      final error = badResponse(
        statusCode: 429,
        data: {'error': {'message': 'inference exceeds tpm/rpm limit'}},
      );
      final text = await SensenovaQuotaPolicy.readErrorBody(error);
      expect(text, contains('tpm'));
    });

    test('HTTP 2xx 绝不去消费响应流（那是业务正文）', () async {
      final error = badResponse(
        statusCode: 200,
        data: ResponseBody(Stream.value(Uint8List.fromList(utf8.encode('data: hi'))), 200),
      );
      expect(await SensenovaQuotaPolicy.readErrorBody(error), isNull);
    });

    test('超长错误体按 maxChars 截断，够判定即可', () async {
      final filler = 'x' * 4000;
      final longBody = '${filler}RateLimitExceeded.EndpointTPMExceeded';
      final error = badResponse(
        statusCode: 429,
        data: ResponseBody.fromString(longBody, 429),
      );

      final text = await SensenovaQuotaPolicy.readErrorBody(error, maxChars: 100);
      expect(text, isNotNull);
      expect(text!.length, equals(100));
      expect(longBody.startsWith(text), isTrue);
    });
  });

  group('错误规则表（声明式判据）', () {
    test('rpm exhausted 归 TPM 而不是 rps：分钟窗口该排队，不是 2 秒后复用', () {
      // `code: 8` 同时覆盖 rps 与 rpm，旧实现一律按 rps 处理，于是只关 2 秒就复用，
      // 同一分钟里必然再撞一次，白白吃掉一次发信深度。
      const rpmBody = '{"error":{"message":"rpm exhausted","code":"8"}}';
      expect(
        SensenovaQuotaPolicy.classify(statusCode: 429, bodyText: rpmBody),
        equals(QuotaSignal.tpm),
      );
    });

    test('规则顺序：同一条正文里 rps 字样比泛化额度字样优先', () {
      final verdict = SensenovaQuotaPolicy.verdict(
        statusCode: 429,
        bodyText: 'quota exceeded, rps exhausted',
      );
      expect(verdict.signal, equals(QuotaSignal.rpsBurst));
      expect(verdict.rule, isNotNull, reason: '命中表内规则时要能回溯是哪条');
    });

    test('规则可自带冷却时长（比形态默认值更精准）', () {
      SensenovaQuotaPolicy.apply({
        'error_rules': [
          {
            'contains': ['model not found'],
            'signal': 'auth',
            'cooldown_seconds': 1800,
          },
        ],
      });
      final verdict = SensenovaQuotaPolicy.verdict(
        statusCode: 404,
        bodyText: 'model not found',
      );
      expect(verdict.signal, equals(QuotaSignal.auth));
      expect(verdict.keyCooldown, equals(const Duration(minutes: 30)));
    });

    test('正文与状态码同时给出时必须都命中（5xx 不被额度规则抢走）', () {
      // 网关 500 的正文里出现 "rate limit" 字样：应判网关故障（不换 Key、不打冷却），
      // 而不是判成额度耗尽去关一把健康 Key
      final signal = SensenovaQuotaPolicy.classify(
        statusCode: 503,
        bodyText: 'upstream said: rate limit exceeded',
      );
      expect(signal, equals(QuotaSignal.server));
    });
  });

  group('apply（云端下发 quota_policy）', () {
    test('只覆盖给出的字段，其余保持内置默认', () {
      SensenovaQuotaPolicy.apply({'pool_max_attempts': 2});
      expect(SensenovaQuotaPolicy.poolMaxAttempts, equals(2));
      expect(SensenovaQuotaPolicy.maxQuotaHold.inSeconds, equals(45));
      expect(SensenovaQuotaPolicy.freeGatewayMaxTokens, equals(16000));
      expect(SensenovaQuotaPolicy.perRequestKeyRotation, isTrue);
    });

    test('取值即时生效于决策函数，不需要重建对象', () {
      SensenovaQuotaPolicy.apply({'tpm_cooldown_seconds': 120});
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.tpm).inSeconds, equals(120));
    });

    test('越界与脏值被钳制或忽略，云端 JSON 被污染也只会退回默认', () {
      SensenovaQuotaPolicy.apply({
        'pool_max_attempts': 9999, // 超池容量 → 钳到 9
        'min_send_interval_ms': -100, // 负数 → 钳到 0
        'tpm_cooldown_seconds': 'abc', // 非数字 → 忽略
        'max_quota_hold_seconds': null, // 缺值 → 忽略
        'per_request_key_rotation': 'yes', // 类型不对 → 忽略
        'free_gateway_max_tokens': 10, // 低于下限 → 钳到 1024
      });
      expect(SensenovaQuotaPolicy.poolMaxAttempts, equals(9));
      expect(SensenovaQuotaPolicy.minSendInterval, equals(Duration.zero));
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.tpm).inSeconds, equals(60));
      expect(SensenovaQuotaPolicy.maxQuotaHold.inSeconds, equals(45));
      expect(SensenovaQuotaPolicy.perRequestKeyRotation, isTrue);
      expect(SensenovaQuotaPolicy.freeGatewayMaxTokens, equals(1024));
    });

    test('空载荷与 null 一律不动现有策略', () {
      SensenovaQuotaPolicy.apply({'tpm_cooldown_seconds': 30});
      SensenovaQuotaPolicy.apply(null);
      SensenovaQuotaPolicy.apply({});
      expect(SensenovaQuotaPolicy.keyCooldown(QuotaSignal.tpm).inSeconds, equals(30));
    });

    test('非法 error_rules（全是不认识的 signal）不会清空规则表', () {
      SensenovaQuotaPolicy.apply({
        'error_rules': [
          {'contains': ['whatever'], 'signal': 'nonsense'},
          {'signal': 'tpm'}, // 没有任何判据条件，等于无条件命中 → 必须丢弃
        ],
      });
      expect(
        SensenovaQuotaPolicy.activeRuleCount,
        equals(SensenovaQuotaPolicy.builtinRules.length),
      );
      expect(
        SensenovaQuotaPolicy.classify(statusCode: 429),
        equals(QuotaSignal.tpm),
        reason: '默认判据仍然可用',
      );
    });

    test('下发可整体关掉逐请求换 Key（应急回退通道）', () {
      SensenovaQuotaPolicy.apply({
        'per_request_key_rotation': false,
        'send_stream_usage': true,
      });
      expect(SensenovaQuotaPolicy.perRequestKeyRotation, isFalse);
      expect(SensenovaQuotaPolicy.sendStreamUsage, isTrue);
    });

    test('stream_options 默认关闭：未实测的参数不能默认下发给网关', () {
      // 未知参数导致的 400 是确定性错误，会把每一次对话都打死（重试也救不回来）
      expect(SensenovaQuotaPolicy.sendStreamUsage, isFalse);
    });
  });

  group('策略常量', () {
    test('重试深度与节流取值符合设计', () {
      expect(SensenovaQuotaPolicy.poolMaxAttempts, equals(4));
      expect(SensenovaQuotaPolicy.minSendInterval.inMilliseconds, equals(250));
      expect(SensenovaQuotaPolicy.maxQuotaHold.inSeconds, equals(45));
      expect(SensenovaQuotaPolicy.freeGatewayMaxTokens, equals(16000));
      expect(
        SensenovaQuotaPolicy.poolMaxAttempts,
        lessThanOrEqualTo(FreeModelKeyManager.instance.totalKeysCount),
        reason: '尝试深度不能超过池容量，否则同一把 Key 会在一次请求内被重复端上来',
      );
      expect(SensenovaQuotaPolicy.maxQuotaHold > SensenovaQuotaPolicy.minSendInterval, isTrue);
    });
  });
}
