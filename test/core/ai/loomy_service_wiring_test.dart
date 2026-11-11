import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/loomy_auth_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// Loomy 发信接线：token + Authorization 双头、charset 与请求体适配
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 1, 1);
  late _RecordingAdapter adapter;
  late AiService service;

  AiProvider loomyProvider() => AiProvider(
    id: 'pLoomy',
    vendorId: 'loomy',
    name: 'Loomy（讯飞）',
    providerType: 'openai',
    baseUrl: LoomyAuthService.chatBase,
    authMode: AiProvider.authModeLoomy,
    apiKeys: const [],
    models: const [AiProviderModel(id: 'Kimi-k2.6', name: 'Kimi k2.6')],
    createdAt: now,
    updatedAt: now,
  );

  List<ChatMessage> messages() => [ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now())];

  setUp(() {
    LoomyAuthService.accessTokenLoaderForTest = (_) async => 'loomy-session';
    adapter = _RecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
  });

  tearDown(() {
    LoomyAuthService.accessTokenLoaderForTest = null;
  });

  test('Loomy：token 与 Authorization 同时注入，Content-Type 带 charset', () async {
    final provider = loomyProvider();
    service.updateConfig(AiConfig.fromProvider(provider, 'Kimi-k2.6'));

    final reply = await service.chatResponse(messages());

    expect(reply.content, 'ok');
    expect(adapter.uris.single, 'https://loomyad.xunfei.cn/api/v1/chat/completions');
    expect(adapter.tokens.single, 'loomy-session');
    expect(adapter.authHeaders.single, 'Bearer loomy-session');
    // 不带 charset 时上游按 GBK 解码，中文会乱码
    expect(adapter.contentTypes.single, contains('charset=utf-8'));

    // 请求体里的 max_tokens 不属于 Loomy 的适配范围，应原样保留
    expect(adapter.bodies.single.containsKey('max_tokens'), isTrue);
  });

  test('未登录时发信前报「请重新登录」，不会发出空凭证请求', () async {
    LoomyAuthService.accessTokenLoaderForTest = (_) async => null;
    final provider = loomyProvider();
    service.updateConfig(AiConfig.fromProvider(provider, 'Kimi-k2.6'));

    await expectLater(service.chatResponse(messages()), throwsA(isA<Exception>()));
    expect(adapter.uris, isEmpty);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<String> uris = [];
  final List<String> authHeaders = [];
  final List<String> tokens = [];
  final List<String> contentTypes = [];
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri.toString());
    authHeaders.add(_header(options.headers, 'authorization'));
    tokens.add(_header(options.headers, 'token'));
    contentTypes.add(_header(options.headers, 'content-type'));
    final data = options.data;
    if (data is Map) {
      bodies.add(Map<String, dynamic>.from(data));
    }
    return ResponseBody.fromString(
      _okBody,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  static String _header(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) {
        return entry.value?.toString() ?? '';
      }
    }
    return '';
  }
}

const String _okBody =
    '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
    '"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}';
