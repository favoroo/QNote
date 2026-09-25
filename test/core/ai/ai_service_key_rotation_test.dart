import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/ai/sensenova_quota_policy.dart';
import 'package:qnote_flutter/core/storage/ai_request_stats_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_request_stat.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// AiService 逐请求换 Key 的回归测试（不联网，用假 adapter 断言真实发出的 header）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late _RecordingAdapter adapter;
  late AiService service;
  late List<String> poolKeys;
  late Database db;
  final statsRepo = AiRequestStatsRepository();

  AiConfig poolConfig({String? apiKey}) => AiConfig(
        id: 'free_deepseek-flash',
        name: 'DeepSeek Flash',
        provider: 'openai',
        modelName: 'deepseek-flash',
        apiKey: apiKey ?? poolKeys.first,
        baseUrl: 'https://token.sensenova.cn/v1',
        vendorId: 'free_model',
        createdAt: DateTime(2026, 9, 25),
        updatedAt: DateTime(2026, 9, 25),
      );

  AiConfig customConfig() => AiConfig(
        id: 'custom-1',
        name: '我的模型',
        provider: 'openai',
        modelName: 'some-model',
        apiKey: 'sk-user-owned-key-000000',
        baseUrl: 'https://gw.example.com/v1',
        vendorId: null,
        createdAt: DateTime(2026, 9, 25),
        updatedAt: DateTime(2026, 9, 25),
      );

  setUpAll(() async {
    // 观测落库走真实建表迁移（ffi 后端下各测试 isolate 共用同一个 qnote.db 文件，
    // 因此只在 setUp 里清自己这张表）
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    poolKeys = BuiltinFreeKeys.getDecryptedKeys();
    FreeModelKeyManager.instance.resetForTest();
    SensenovaQuotaPolicy.resetToDefaults();
    adapter = _RecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
    await db.delete(AiRequestStatsRepository.table);
  });

  Future<void> sendTurns(int n, {int? maxTokens}) async {
    for (var i = 0; i < n; i++) {
      await service.chat([
        ChatMessage(role: 'user', content: '第 $i 条'),
      ]);
    }
  }

  group('逐请求换 Key（需求本体）', () {
    test('连续 6 次全部成功的请求，每次用的都是不同的 Key', () async {
      service.updateConfig(poolConfig(), maxTokens: 32000);

      await sendTurns(6);

      expect(adapter.authHeaders.length, equals(6));
      expect(adapter.authHeaders.toSet().length, equals(6), reason: '成功也要换 Key，不能粘着一把');
      for (final header in adapter.authHeaders) {
        expect(poolKeys, contains(_bearerOf(header)));
      }
    });

    test('AgentLoop 的每一轮（同一会话内多次请求）也各自换 Key', () async {
      service.updateConfig(poolConfig());

      // 模拟一次提问触发的 3 轮推理：工具回路里每轮都是一次独立发信
      await service.chat([ChatMessage(role: 'user', content: 'a')]);
      await service.chat([ChatMessage(role: 'user', content: 'b')]);
      await service.chatResponse([
        ChatMessage(role: 'user', content: 'c'),
        ChatMessage(role: 'assistant', content: 'd'),
      ]);

      expect(adapter.authHeaders.toSet().length, equals(3));
    });

    test('不覆写全局 header：并发场景下两条链路不会互相串台', () async {
      service.updateConfig(poolConfig());

      // 交错发起两个请求（AiService 是全 App 单例，旧实现里后一个 updateConfig
      // 会覆写前一个正在使用的 Authorization）
      final first = service.chat([ChatMessage(role: 'user', content: 'x')]);
      final second = service.chat([ChatMessage(role: 'user', content: 'y')]);
      await Future.wait([first, second]);

      expect(adapter.authHeaders.length, equals(2));
      expect(adapter.authHeaders.toSet().length, equals(2));
    });
  });

  group('非内置池路径保持原样', () {
    test('pinApiKey 时锁定用配置的 Key，且不压缩 max_tokens', () async {
      final pinned = poolConfig(apiKey: poolKeys[2]);
      service.updateConfig(pinned, maxTokens: 32000, pinApiKey: true);

      await sendTurns(3);

      expect(adapter.authHeaders.toSet().length, equals(1));
      expect(_bearerOf(adapter.authHeaders.first), equals(poolKeys[2]));
      expect(adapter.lastMaxTokens, equals(32000));
      // 逐把测连通的场景不该把整池拖进轮换
      expect(FreeModelKeyManager.instance.availableKeyCount, equals(poolKeys.length));
    });

    test('用户自配模型不参与池轮换，预算也不被压', () async {
      service.updateConfig(customConfig(), maxTokens: 32000);

      await sendTurns(3);

      expect(adapter.authHeaders.toSet().length, equals(1));
      expect(_bearerOf(adapter.authHeaders.first), equals('sk-user-owned-key-000000'));
      expect(adapter.lastMaxTokens, equals(32000));
    });

    test('内置池的 max_tokens 被压到免费网关上限', () async {
      service.updateConfig(poolConfig(), maxTokens: 32000);

      await sendTurns(1);

      expect(adapter.lastMaxTokens, equals(SensenovaQuotaPolicy.freeGatewayMaxTokens));
    });
  });

  group('限流时的换 Key 与冷却归因', () {
    test('TPM 限流：按 poolMaxAttempts 把把不同 Key，且只冷却各自用过的那把', () async {
      adapter.failWith(statusCode: 429, body: _tpmBody, failFirst: 99);
      service.updateConfig(poolConfig());

      await expectLater(
        service.chat([ChatMessage(role: 'user', content: 'hi')]),
        throwsA(isA<DioException>()),
      );

      final used = adapter.authHeaders.map(_bearerOf).toList();
      expect(used.length, equals(SensenovaQuotaPolicy.poolMaxAttempts));
      expect(used.toSet().length, equals(used.length), reason: '重试必须换新 Key');
      expect(
        FreeModelKeyManager.instance.availableKeyCount,
        equals(poolKeys.length - SensenovaQuotaPolicy.poolMaxAttempts),
      );
    });

    test('5xx 不归因到 Key：池子容量不掉', () async {
      adapter.failWith(
        statusCode: 503,
        body: '{"error":{"message":"gateway down"}}',
        failFirst: 99,
      );
      service.updateConfig(poolConfig());

      await expectLater(
        service.chat([ChatMessage(role: 'user', content: 'hi')]),
        throwsA(isA<DioException>()),
      );

      expect(FreeModelKeyManager.instance.availableKeyCount, equals(poolKeys.length));
    });

    test('整池都在冷却时排队等回填，而不是第一次 429 就放弃', () async {
      // 先把整池置入一个短冷却（模拟「刚被限流」，但马上就要回填）
      for (final key in poolKeys) {
        FreeModelKeyManager.instance.markKeyLimited(
          key,
          cooldown: const Duration(milliseconds: 600),
        );
      }
      expect(FreeModelKeyManager.instance.hasAvailableKey(), isFalse);

      // 第一次请求 429，排队回填后第二次成功
      adapter.failWith(statusCode: 429, body: _tpmBody, failFirst: 1);
      service.updateConfig(poolConfig());

      final startedAt = DateTime.now();
      final reply = await service.chat([ChatMessage(role: 'user', content: 'hi')]);
      final waited = DateTime.now().difference(startedAt);

      expect(reply, equals('ok'));
      expect(adapter.authHeaders.length, greaterThan(1));
      expect(
        waited.inMilliseconds,
        greaterThanOrEqualTo(500),
        reason: '必须真的等到冷却到期再发，而不是立刻重发撞同一个 429',
      );
      // 首发用的那把确实被限流，按 TPM 记 60 秒冷却；其余 8 把已回填可用
      expect(
        FreeModelKeyManager.instance.availableKeyCount,
        equals(poolKeys.length - 1),
      );
    });

    test('排队会把等待时长报给状态行（onQuotaHold 被回调）', () async {
      for (final key in poolKeys) {
        FreeModelKeyManager.instance.markKeyLimited(
          key,
          cooldown: const Duration(milliseconds: 500),
        );
      }
      adapter.failWith(statusCode: 429, body: _tpmBody, failFirst: 1);
      service.updateConfig(poolConfig());

      final holds = <Duration>[];
      await service.chatStreamWithTools(
        messages: [ChatMessage(role: 'user', content: 'hi')],
        onQuotaHold: holds.add,
      ).drain<void>();

      expect(holds, isNotEmpty, reason: '排队时要把等待时长报给状态行，别让用户对着静止的「思考中」发呆');
    });

    test('超出排队预算才放弃，且用的 Key 彼此不同', () async {
      // 60 秒冷却：远超 maxQuotaHold(45s)，应当放弃而不是干等
      for (final key in poolKeys) {
        FreeModelKeyManager.instance.markKeyLimited(key, cooldown: const Duration(seconds: 60));
      }
      adapter.failWith(statusCode: 429, body: _tpmBody, failFirst: 99);
      service.updateConfig(poolConfig());

      final startedAt = DateTime.now();
      await expectLater(
        service.chat([ChatMessage(role: 'user', content: 'hi')]),
        throwsA(isA<DioException>()),
      );
      expect(
        DateTime.now().difference(startedAt).inSeconds,
        lessThan(SensenovaQuotaPolicy.maxQuotaHold.inSeconds),
        reason: '等不到的情况要快速失败',
      );
      // 第一次 429 就发现最早解锁在 60 秒外 → 直接放弃，只发一次
      expect(adapter.authHeaders.length, equals(1));
    });
  });

  group('逐请求观测落库（诊断表的数据来源）', () {
    test('每次成功发信落一行：Key 掩码各不相同、模型与 usage 对得上', () async {
      service.updateConfig(poolConfig());

      await sendTurns(3);
      await service.flushRequestStatsForTest();

      final rows = await statsRepo.all();
      expect(rows, hasLength(3));
      expect(rows.every((r) => r.outcome == AiRequestOutcomes.ok), isTrue);
      expect(rows.every((r) => r.modelId == 'deepseek-flash'), isTrue);
      expect(
        rows.map((r) => r.keyMask).toSet().length,
        equals(3),
        reason: '观测必须归因到真正发信的那把 Key，否则面板的「哪把 Key 最容易撞墙」答不出来',
      );
      for (final row in rows) {
        expect(row.latencyMs, greaterThanOrEqualTo(0));
        // 掩码而不是明文：这张表会随 WebDAV 备份导出
        expect(row.keyMask.contains('...'), isTrue);
        expect(row.keyMask.length, lessThan(16));
      }
      // 假响应体里带了 usage，说明非流式路径的 token 解析链路是通的
      expect(rows.first.promptTokens, equals(1));
      expect(rows.first.completionTokens, equals(1));
    });

    test('TPM 耗尽重试深度时，每一次撞墙都各记一行', () async {
      adapter.failWith(statusCode: 429, body: _tpmBody, failFirst: 99);
      service.updateConfig(poolConfig());

      await expectLater(
        service.chat([ChatMessage(role: 'user', content: 'hi')]),
        throwsA(isA<DioException>()),
      );
      await service.flushRequestStatsForTest();

      final rows = await statsRepo.all();
      expect(rows.length, equals(SensenovaQuotaPolicy.poolMaxAttempts));
      expect(
        rows.every((r) => r.outcome == AiRequestOutcomes.tpm),
        isTrue,
        reason: '限流分布是本表最重要的指标，漏记就等于面板上看不见问题',
      );
      expect(rows.every((r) => r.httpStatus == 429), isTrue);
      expect(rows.map((r) => r.keyMask).toSet().length, equals(rows.length));
    });

    test('流式路径记首字延迟与末帧 usage', () async {
      adapter.respondWith(
        'data: {"choices":[{"delta":{"content":"你"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"好"}}]}\n\n'
        'data: {"choices":[],"usage":{"prompt_tokens":18000,"completion_tokens":7}}\n\n'
        'data: [DONE]\n\n',
      );
      service.updateConfig(poolConfig());

      await service
          .chatStreamWithTools(messages: [ChatMessage(role: 'user', content: 'hi')])
          .drain<void>();
      await service.flushRequestStatsForTest();

      final rows = await statsRepo.all();
      expect(rows, hasLength(1));
      expect(rows.single.outcome, equals(AiRequestOutcomes.ok));
      expect(rows.single.ttftMs, isNotNull, reason: '换 Key 是否拖慢首包，只看这一列');
      expect(rows.single.promptTokens, equals(18000));
      expect(rows.single.scene, isNotEmpty);
    });

    test('用户自配模型与逐把测连通都不进表，避免污染内置池的分布', () async {
      service.updateConfig(customConfig());
      await sendTurns(2);
      await service.flushRequestStatsForTest();
      expect(await statsRepo.all(), isEmpty, reason: '自配端点不是这套策略层的调参对象');

      service.updateConfig(poolConfig(apiKey: poolKeys.first), pinApiKey: true);
      await sendTurns(2);
      await service.flushRequestStatsForTest();
      expect(
        await statsRepo.all(),
        isEmpty,
        reason: '连通性测试是人为的单 Key 请求，混进来会让限流分布失真',
      );
    });

    test('下发的深度同时改变发信次数与观测行数（策略与观测同源）', () async {
      SensenovaQuotaPolicy.apply({'pool_max_attempts': 2});
      adapter.failWith(statusCode: 429, body: _tpmBody, failFirst: 99);
      service.updateConfig(poolConfig());

      await expectLater(
        service.chat([ChatMessage(role: 'user', content: 'hi')]),
        throwsA(isA<DioException>()),
      );
      await service.flushRequestStatsForTest();

      expect(
        await statsRepo.count(),
        equals(2),
        reason: '阈值必须真的是运行时读取的，否则云端下发无效',
      );
    });
  });
}

const String _tpmBody = '{"error":{"message":"inference exceeds tpm/rpm limit",'
    '"type":"rate_limit_error","code":"RateLimitExceeded.EndpointTPMExceeded"}}';

String _bearerOf(String header) => header.startsWith('Bearer ')
    ? header.substring(7)
    : header;

/// 记录每次请求真实 header 与请求体的假 adapter
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter();

  final List<String> authHeaders = [];
  final List<Object?> bodies = [];
  int? _failStatus;
  String? _failBody;
  String? _okOverride;
  int _failFirst = 1;
  int _calls = 0;

  /// 覆盖成功响应体（流式用例要塞 SSE 帧进来）
  void respondWith(String body) => _okOverride = body;

  /// 让前 [failFirst] 次请求返回该错误，之后的请求恢复正常
  void failWith({required int statusCode, required String body, int failFirst = 1}) {
    _failStatus = statusCode;
    _failBody = body;
    _failFirst = failFirst;
  }

  /// 最后一次请求体里的 max_tokens（非流式路径 data 是 Map，流式路径是 JSON 字符串）
  int? get lastMaxTokens {
    for (final raw in bodies.reversed) {
      Map? decoded;
      if (raw is Map) {
        decoded = raw;
      } else if (raw is String) {
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) decoded = parsed;
        } on FormatException {
          continue;
        }
      }
      if (decoded != null && decoded.containsKey('max_tokens')) {
        return (decoded['max_tokens'] as num).toInt();
      }
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _calls++;
    authHeaders.add(_findHeader(options.headers, 'authorization'));
    bodies.add(options.data);

    final failing = _failStatus != null && _calls <= _failFirst;
    final status = failing ? _failStatus! : 200;
    final body = failing ? _failBody! : (_okOverride ?? _okBody);
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  static String _findHeader(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value?.toString() ?? '';
    }
    return '';
  }
}

const String _okBody = '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
    '"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}';
