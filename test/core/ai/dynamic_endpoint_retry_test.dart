import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';

void main() {
  group('FreeModelService.parseCpaEndpointPayload', () {
    test('Map 载荷：解析 primary 与 fallback', () {
      final pair = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
        'fallback_base_url': 'https://backup.example.com/v1',
      });
      expect(pair, isNotNull);
      expect(pair!.primary, 'https://gw.example.com/v1');
      expect(pair.fallback, 'https://backup.example.com/v1');
    });

    test('fallback 与 primary 相同时不单列', () {
      final pair = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
        'fallback_base_url': 'https://gw.example.com/v1',
      });
      expect(pair, isNotNull);
      expect(pair!.fallback, isNull);
    });

    test('fallback 缺失时为 null', () {
      final pair = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
      });
      expect(pair, isNotNull);
      expect(pair!.fallback, isNull);
    });

    test('JSON 字符串载荷可解析', () {
      const payload =
          '{"primary_base_url":"https://gw.example.com/v1",'
          '"fallback_base_url":"https://backup.example.com/v1"}';
      final pair = FreeModelService.parseCpaEndpointPayload(payload);
      expect(pair, isNotNull);
      expect(pair!.primary, 'https://gw.example.com/v1');
      expect(pair.fallback, 'https://backup.example.com/v1');
    });

    test('primary 缺失或为空时返回 null', () {
      expect(FreeModelService.parseCpaEndpointPayload({}), isNull);
      expect(
        FreeModelService.parseCpaEndpointPayload({'primary_base_url': '  '}),
        isNull,
      );
      expect(FreeModelService.parseCpaEndpointPayload(null), isNull);
    });

    test('非法 URL 一律拒绝（防云端 JSON 污染）', () {
      expect(
        FreeModelService.parseCpaEndpointPayload(
          {'primary_base_url': 'ftp://gw.example.com/v1'},
        ),
        isNull,
      );
      expect(
        FreeModelService.parseCpaEndpointPayload(
          {'primary_base_url': 'http://gw.example.com/v1'},
        ),
        isNull,
      );
      expect(
        FreeModelService.parseCpaEndpointPayload(
          {'primary_base_url': 'not-a-url'},
        ),
        isNull,
      );
      expect(
        FreeModelService.parseCpaEndpointPayload(
          {'primary_base_url': 'https:///no-host'},
        ),
        isNull,
      );
    });

    test('fallback 非法时被丢弃但不影响 primary', () {
      final pair = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
        'fallback_base_url': 'http://bad.example.com/v1',
      });
      expect(pair, isNotNull);
      expect(pair!.primary, 'https://gw.example.com/v1');
      expect(pair.fallback, isNull);
    });

    test('尾部多余斜杠被归一化去除', () {
      final pair = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com///',
      });
      expect(pair, isNotNull);
      expect(pair!.primary, 'https://gw.example.com');
    });

    test('updated_at 提取到载荷，缺失或为空时为 null', () {
      final pair = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
        'updated_at': '2026-09-13T00:43:13Z',
      });
      expect(pair!.updatedAt, '2026-09-13T00:43:13Z');

      final noTime = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
      });
      expect(noTime!.updatedAt, isNull);

      final emptyTime = FreeModelService.parseCpaEndpointPayload({
        'primary_base_url': 'https://gw.example.com/v1',
        'updated_at': '   ',
      });
      expect(emptyTime!.updatedAt, isNull);
    });

    test('非法 JSON 字符串返回 null', () {
      expect(
        FreeModelService.parseCpaEndpointPayload('{broken json'),
        isNull,
      );
    });
  });

  group('FreeModelService.selectLatestCpaEndpoint', () {
    CpaEndpointPair pair(String primary, [String? updatedAt]) =>
        CpaEndpointPair(primary: primary, updatedAt: updatedAt);

    test('空列表或全无效候选返回 null', () {
      expect(FreeModelService.selectLatestCpaEndpoint([]), isNull);
      expect(
        FreeModelService.selectLatestCpaEndpoint([null, null]),
        isNull,
      );
    });

    test('多个候选取 updated_at 最新者', () {
      final latest = FreeModelService.selectLatestCpaEndpoint([
        pair('https://old.example.com/v1', '2026-09-13T00:43:13Z'),
        pair('https://new.example.com/v1', '2026-09-13T08:44:58Z'),
        pair('https://mid.example.com/v1', '2026-09-13T04:00:00Z'),
      ]);
      expect(latest!.primary, 'https://new.example.com/v1');
    });

    test('带时间戳的候选优先于无时间戳候选', () {
      final latest = FreeModelService.selectLatestCpaEndpoint([
        pair('https://no-time.example.com/v1'),
        pair('https://timed.example.com/v1', '2020-01-01T00:00:00Z'),
      ]);
      expect(latest!.primary, 'https://timed.example.com/v1');
    });

    test('全部无时间戳时首个有效候选兜底胜出', () {
      final latest = FreeModelService.selectLatestCpaEndpoint([
        null,
        pair('https://first.example.com/v1'),
        pair('https://second.example.com/v1'),
      ]);
      expect(latest!.primary, 'https://first.example.com/v1');
    });

    test('非法时间串视为无时间戳', () {
      final latest = FreeModelService.selectLatestCpaEndpoint([
        pair('https://bad-time.example.com/v1', 'not-a-time'),
        pair('https://good-time.example.com/v1', '2026-09-13T08:44:58Z'),
      ]);
      expect(latest!.primary, 'https://good-time.example.com/v1');
    });

    test('单候选直接返回（含 null 混杂）', () {
      final latest = FreeModelService.selectLatestCpaEndpoint([
        null,
        pair('https://only.example.com/v1', '2026-09-13T08:44:58Z'),
      ]);
      expect(latest!.primary, 'https://only.example.com/v1');
    });
  });

  group('BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl', () {
    test('正常地址归一化：去尾斜杠并补 /v1', () {
      BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl('https://b.example.com');
      expect(
        BuiltinFreeKeys.dynamicCpaFallbackBaseUrl,
        'https://b.example.com/v1',
      );
    });

    test('空值清除备用地址', () {
      BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl('https://b.example.com');
      BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl('');
      expect(BuiltinFreeKeys.dynamicCpaFallbackBaseUrl, isEmpty);
      BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl(null);
      expect(BuiltinFreeKeys.dynamicCpaFallbackBaseUrl, isEmpty);
    });
  });

  group('FreeModelKeyManager.isConnectionClassError', () {
    RequestOptions requestOptions() => RequestOptions(path: '/v1/chat/completions');

    test('unknown + HandshakeException（本次日志中的真实形态）判定为连接类', () {
      final error = DioException(
        requestOptions: requestOptions(),
        type: DioExceptionType.unknown,
        error: const HandshakeException('Connection terminated during handshake'),
      );
      expect(FreeModelKeyManager.instance.isConnectionClassError(error), isTrue);
    });

    test('unknown + SocketException 判定为连接类', () {
      final error = DioException(
        requestOptions: requestOptions(),
        type: DioExceptionType.unknown,
        error: const SocketException('Connection reset by peer'),
      );
      expect(FreeModelKeyManager.instance.isConnectionClassError(error), isTrue);
    });

    test('connectionTimeout / connectionError 判定为连接类', () {
      final timeout = DioException(
        requestOptions: requestOptions(),
        type: DioExceptionType.connectionTimeout,
      );
      final connErr = DioException(
        requestOptions: requestOptions(),
        type: DioExceptionType.connectionError,
      );
      expect(FreeModelKeyManager.instance.isConnectionClassError(timeout), isTrue);
      expect(FreeModelKeyManager.instance.isConnectionClassError(connErr), isTrue);
    });

    test('unknown + FormatException（数据问题）不是连接类', () {
      final error = DioException(
        requestOptions: requestOptions(),
        type: DioExceptionType.unknown,
        error: const FormatException('bad json'),
      );
      expect(FreeModelKeyManager.instance.isConnectionClassError(error), isFalse);
    });

    test('HTTP 429 等状态码错误不是连接类', () {
      final error = DioException(
        requestOptions: requestOptions(),
        response: Response(requestOptions: requestOptions(), statusCode: 429),
      );
      expect(FreeModelKeyManager.instance.isConnectionClassError(error), isFalse);
    });

    test('receiveTimeout 保持通用桶（不启用长窗口）', () {
      final error = DioException(
        requestOptions: requestOptions(),
        type: DioExceptionType.receiveTimeout,
      );
      expect(FreeModelKeyManager.instance.isConnectionClassError(error), isFalse);
    });

    test('非 DioException 不是连接类', () {
      expect(
        FreeModelKeyManager.instance.isConnectionClassError(
          Exception('Connection terminated during handshake'),
        ),
        isFalse,
      );
    });

    test('连接类错误必然属于可重试错误（分类一致性）', () {
      final samples = <DioException>[
        DioException(
          requestOptions: requestOptions(),
          type: DioExceptionType.unknown,
          error: const HandshakeException('Connection terminated during handshake'),
        ),
        DioException(
          requestOptions: requestOptions(),
          type: DioExceptionType.unknown,
          error: const SocketException('Connection refused'),
        ),
        DioException(
          requestOptions: requestOptions(),
          type: DioExceptionType.connectionTimeout,
        ),
        DioException(
          requestOptions: requestOptions(),
          type: DioExceptionType.connectionError,
        ),
      ];
      for (final error in samples) {
        expect(
          FreeModelKeyManager.instance.isRecoverableError(error),
          isTrue,
          reason: '$error 应同时被 isRecoverableError 覆盖',
        );
      }
    });
  });

  group('FreeModelKeyManager.getConnectionBackoffDelay', () {
    test('退避序列为 1s/2s/4s/8s 并带 0~150ms 抖动', () {
      final bounds = [1000, 2000, 4000, 8000];
      for (int i = 0; i < bounds.length; i++) {
        final delay =
            FreeModelKeyManager.instance.getConnectionBackoffDelay(i + 1);
        expect(delay.inMilliseconds, greaterThanOrEqualTo(bounds[i]));
        expect(delay.inMilliseconds, lessThanOrEqualTo(bounds[i] + 150));
      }
    });

    test('超出第 4 次后封顶在 8s 档', () {
      final delay =
          FreeModelKeyManager.instance.getConnectionBackoffDelay(10);
      expect(delay.inMilliseconds, greaterThanOrEqualTo(8000));
      expect(delay.inMilliseconds, lessThanOrEqualTo(8150));
    });

    test('通用退避 getBackoffDelay 保持原有 300ms 基数不变', () {
      final delay = FreeModelKeyManager.instance.getBackoffDelay(1);
      expect(delay.inMilliseconds, greaterThanOrEqualTo(300));
      expect(delay.inMilliseconds, lessThanOrEqualTo(450));
    });
  });
}
