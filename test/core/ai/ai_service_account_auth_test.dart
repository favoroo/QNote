import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 订阅账号型厂商的发信接线：token 现取、端点与模型正确
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 1, 1);
  late _RecordingAdapter adapter;
  late AiService service;

  AiProvider raccoonProvider() => AiProvider(
    id: 'pRaccoon',
    vendorId: 'raccoon',
    name: '商汤小浣熊',
    providerType: 'openai',
    baseUrl: 'https://xiaohuanxiong.com/api/web/llm/v2',
    authMode: AiProvider.authModeRaccoon,
    apiKeys: const [],
    models: const [AiProviderModel(id: 'raccoon-chat-ml-5-5', name: 'Raccoon Chat')],
    createdAt: now,
    updatedAt: now,
  );

  List<ChatMessage> messages() => [ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now())];

  setUp(() {
    RaccoonAuthService.accessTokenLoaderForTest = (_) async => 'jwt-test-token';
    adapter = _RecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
  });

  tearDown(() {
    RaccoonAuthService.accessTokenLoaderForTest = null;
  });

  test('账号型厂商：token 逐请求注入，打到小浣熊的 OpenAI 兼容端点', () async {
    final provider = raccoonProvider();
    service.updateConfig(AiConfig.fromProvider(provider, 'raccoon-chat-ml-5-5'));

    final reply = await service.chatResponse(messages());

    expect(reply.content, 'ok');
    expect(adapter.uris.single, 'https://xiaohuanxiong.com/api/web/llm/v2/chat/completions');
    expect(adapter.authHeaders.single, 'Bearer jwt-test-token');
    expect(adapter.models.single, 'raccoon-chat-ml-5-5');
  });

  test('未登录时发信前就报「请重新登录」，不会发出空凭证请求', () async {
    RaccoonAuthService.accessTokenLoaderForTest = (_) async => null;
    final provider = raccoonProvider();
    service.updateConfig(AiConfig.fromProvider(provider, 'raccoon-chat-ml-5-5'));

    await expectLater(service.chatResponse(messages()), throwsA(isA<RaccoonAuthRequiredException>()));
    expect(adapter.uris, isEmpty);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<String> uris = [];
  final List<String> models = [];
  final List<String> authHeaders = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri.toString());
    authHeaders.add(_header(options.headers, 'authorization'));
    final data = options.data;
    if (data is Map && data['model'] != null) {
      models.add(data['model'].toString());
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
