import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// AiService 密钥池轮询的回归测试（不联网，用假 adapter 断言真实发出的 header）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAdapter adapter;
  late AiService service;

  AiConfig config() => AiConfig(
        providerId: 'provider-1',
        name: 'demo',
        provider: 'openai',
        modelName: 'demo-model',
        apiKey: 'sk-first-0000000000',
        baseUrl: 'https://gw.example.com/v1',
        vendorId: 'custom',
      );

  setUp(() {
    ApiKeyPool.instance.resetForTest();
    adapter = _RecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
    AiService.providerKeysLoaderForTest =
        (_) async => ['sk-aaa-11111111', 'sk-bbb-22222222'];
  });

  tearDown(() {
    AiService.providerKeysLoaderForTest = null;
  });

  Future<String> send() => service.chat([
        ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now()),
      ]);

  test('多 Key 厂商逐请求轮换 Authorization（成功也换）', () async {
    service.updateConfig(config());

    await send();
    await send();
    await send();

    expect(adapter.authHeaders, [
      'Bearer sk-aaa-11111111',
      'Bearer sk-bbb-22222222',
      'Bearer sk-aaa-11111111',
    ]);
  });

  test('单 Key 厂商沿用配置里的 Key，不额外覆写', () async {
    AiService.providerKeysLoaderForTest = (_) async => ['sk-only-99999999'];
    service.updateConfig(config());

    await send();

    expect(adapter.authHeaders.single, 'Bearer sk-first-0000000000');
  });

  test('429 撞墙后冷却当前 Key，并换下一把重试', () async {
    service.updateConfig(config());
    adapter.failWith(
      statusCode: 429,
      body: '{"error":{"message":"rate limit exceeded"}}',
      failFirst: 1,
    );

    final reply = await send();

    expect(reply, 'ok');
    expect(adapter.authHeaders.length, 2);
    expect(adapter.authHeaders[0], 'Bearer sk-aaa-11111111');
    expect(adapter.authHeaders[1], 'Bearer sk-bbb-22222222');
    expect(
      ApiKeyPool.instance.cooldownRemaining('provider-1', 'sk-aaa-11111111'),
      greaterThan(Duration.zero),
      reason: '撞墙的 Key 必须进入冷却，否则下一轮请求会再次端上来',
    );
  });

  test('gemini 接口类型用 x-goog-api-key 覆写轮换', () async {
    final gemini = AiConfig(
      providerId: 'provider-1',
      name: 'gemini',
      provider: 'gemini',
      modelName: 'gemini-pro',
      apiKey: 'sk-first-0000000000',
      baseUrl: 'https://generativelanguage.googleapis.com',
      vendorId: 'gemini',
    );
    service.updateConfig(gemini);

    await send();

    expect(adapter.googHeaders.single, 'sk-aaa-11111111');
    expect(adapter.authHeaders.single, isEmpty);
  });

  test('锁定 Key 的连通性测试不参与轮换', () async {
    service.updateConfig(config(), pinApiKey: true);

    await send();

    expect(adapter.authHeaders.single, 'Bearer sk-first-0000000000');
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<String> authHeaders = [];
  final List<String> googHeaders = [];
  int? _failStatus;
  int _failFirst = 0;
  int _calls = 0;
  String _failBody = '';

  void failWith({
    required int statusCode,
    required String body,
    int failFirst = 1,
  }) {
    _failStatus = statusCode;
    _failFirst = failFirst;
    _failBody = body;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _calls++;
    authHeaders.add(_header(options.headers, 'authorization'));
    googHeaders.add(_header(options.headers, 'x-goog-api-key'));

    final failing = _failStatus != null && _calls <= _failFirst;
    return ResponseBody.fromString(
      failing ? _failBody : _okBody,
      failing ? _failStatus! : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  static String _header(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value?.toString() ?? '';
    }
    return '';
  }
}

const String _okBody = '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
    '"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}';