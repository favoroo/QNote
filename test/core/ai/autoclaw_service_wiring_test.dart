import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/autoclaw_auth_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// AutoClaw 发信接线：X-Authorization、国内网关端点与请求体适配
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 1, 1);
  late _RecordingAdapter adapter;
  late AiService service;

  AiProvider autoClawProvider() => AiProvider(
    id: 'pAutoClaw',
    vendorId: 'autoclaw-cn',
    name: 'AutoClaw（智谱·国内）',
    providerType: 'openai',
    baseUrl: AutoClawAuthService.chatBase,
    authMode: AiProvider.authModeAutoClaw,
    apiKeys: const [],
    models: const [AiProviderModel(id: 'zai_auto', name: 'GLM Auto')],
    createdAt: now,
    updatedAt: now,
  );

  List<ChatMessage> messages() => [ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now())];

  setUp(() {
    AutoClawAuthService.accessTokenLoaderForTest = (_) async => 'ac-token';
    adapter = _RecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
  });

  tearDown(() {
    AutoClawAuthService.accessTokenLoaderForTest = null;
  });

  test('AutoClaw：X-Authorization 注入到国内网关，请求体补官方前缀', () async {
    final provider = autoClawProvider();
    service.updateConfig(AiConfig.fromProvider(provider, 'zai_auto'));

    final reply = await service.chatResponse(messages());

    expect(reply.content, 'ok');
    expect(
      adapter.uris.single,
      'https://autoglm-acceleration-api.zhipuai.cn'
      '/autoclaw-proxy/proxy/autoclaw/chat/completions',
    );
    // 账号 token 只走 X-Authorization，不能同时带普通 Authorization
    expect(adapter.authHeaders.single, isEmpty);
    expect(adapter.xAuthHeaders.single, 'Bearer ac-token');
    expect(adapter.xChannels.single, 'AutoClaw26');
    expect(adapter.requestModels.single, 'zai_auto');

    final body = adapter.bodies.single;
    expect(body.containsKey('max_tokens'), isFalse);
    final bodyMessages = body['messages'] as List;
    expect((bodyMessages.first as Map)['content'], startsWith(AutoClawAuthService.officialSystemPrompt));
  });

  test('未登录时发信前报「请重新登录」，不会发出空凭证请求', () async {
    AutoClawAuthService.accessTokenLoaderForTest = (_) async => null;
    final provider = autoClawProvider();
    service.updateConfig(AiConfig.fromProvider(provider, 'zai_auto'));

    await expectLater(service.chatResponse(messages()), throwsA(isA<Exception>()));
    expect(adapter.uris, isEmpty);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<String> uris = [];
  final List<String> authHeaders = [];
  final List<String> xAuthHeaders = [];
  final List<String> xChannels = [];
  final List<String> requestModels = [];
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri.toString());
    authHeaders.add(_header(options.headers, 'authorization'));
    xAuthHeaders.add(_header(options.headers, 'x-authorization'));
    xChannels.add(_header(options.headers, 'x-channel'));
    requestModels.add(_header(options.headers, 'x-request-model'));
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
