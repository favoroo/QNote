import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/builtin_provider.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 内置免费模型的发信路径回归测试（不联网，用假 adapter 断言真实发出的 header）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _BuiltinRecordingAdapter adapter;
  late AiService service;

  const builtinConfig = AiConfig(
    providerId: BuiltinProvider.id,
    name: BuiltinProvider.name,
    provider: 'openai',
    modelName: BuiltinProvider.chatModelId,
    apiKey: '',
    baseUrl: 'https://demo.trycloudflare.com/v1',
    vendorId: BuiltinProvider.vendorId,
  );

  const keyedConfig = AiConfig(
    providerId: 'provider-1',
    name: 'demo',
    provider: 'openai',
    modelName: 'demo-model',
    apiKey: 'sk-first-0000000000',
    baseUrl: 'https://gw.example.com/v1',
    vendorId: 'custom',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    adapter = _BuiltinRecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
    // 内置厂商在真实链路里走虚拟条目（无密钥），这里也返回空列表
    AiService.providerKeysLoaderForTest = (_) async => <String>[];
  });

  tearDown(() {
    AiService.providerKeysLoaderForTest = null;
  });

  Future<String> send() => service.chat([ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now())]);

  test('内置厂商发信不带 Authorization，但带安装 ID', () async {
    service.updateConfig(builtinConfig);

    final reply = await send();

    expect(reply, 'ok');
    expect(adapter.authHeaders.single, isEmpty, reason: '内置服务无密钥，绝不能发送 Authorization');
    expect(adapter.installHeaders.single, isNotEmpty, reason: '网关按安装 ID 做设备配额');
    expect(adapter.signHeaders.single, isEmpty, reason: '测试未注入 app secret，不应发送签名');
    expect(adapter.paths.single, endsWith('/v1/chat/completions'));
    expect(adapter.models.single, BuiltinProvider.chatModelId);
  });

  test('从带 Key 的厂商切到内置厂商后不再残留 Authorization', () async {
    service.updateConfig(keyedConfig);
    await send();
    expect(adapter.authHeaders.single, 'Bearer sk-first-0000000000');

    service.updateConfig(builtinConfig);
    await send();

    expect(adapter.authHeaders.length, 2);
    expect(adapter.authHeaders.last, isEmpty, reason: '切换厂商必须清掉上一家的全局 Authorization');
  });
}

class _BuiltinRecordingAdapter implements HttpClientAdapter {
  final List<String> authHeaders = [];
  final List<String> installHeaders = [];
  final List<String> signHeaders = [];
  final List<String> paths = [];
  final List<String> models = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authHeaders.add(_header(options.headers, 'authorization'));
    installHeaders.add(_header(options.headers, 'x-qnote-install'));
    signHeaders.add(_header(options.headers, 'x-qnote-sign'));
    paths.add(options.uri.path);

    final body = options.data;
    if (body is Map && body['model'] is String) {
      models.add(body['model'] as String);
    } else if (body is String) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['model'] is String) {
          models.add(decoded['model'] as String);
        }
      } catch (_) {
        // 忽略非 JSON body
      }
    }

    return ResponseBody.fromString(
      _okBody,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
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

const String _okBody =
    '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
    '"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}';
