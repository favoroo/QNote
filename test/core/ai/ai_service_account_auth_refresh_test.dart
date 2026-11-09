import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 账号型厂商的 401 闭环：刷新一次 token 后用新凭证重发，且只刷新一次
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late _AuthRetryAdapter adapter;
  late AiService service;
  final auth = RaccoonAuthService.instance;

  String jwt(Map<String, dynamic> claims) {
    String enc(dynamic value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${enc({'alg': 'none'})}.${enc(claims)}.sig';
  }

  AiProvider provider() => AiProvider(
        id: 'pRaccoon',
        vendorId: 'raccoon',
        name: '商汤小浣熊',
        providerType: 'openai',
        baseUrl: 'https://xiaohuanxiong.com/api/web/llm/v2',
        authMode: AiProvider.authModeRaccoon,
        apiKeys: const [],
        models: const [
          AiProviderModel(id: 'raccoon-chat-ml-5-5', name: 'Raccoon Chat'),
        ],
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete(AiAccountRepository.tableName);
    auth.resetForTest();
    adapter = _AuthRetryAdapter();
    auth.httpClientAdapterForTest = adapter;
    service = AiService();
    service.httpClientAdapterForTest = adapter;
    service.updateConfig(
      AiConfig.fromProvider(provider(), 'raccoon-chat-ml-5-5'),
    );

    // 登录态本身还没过期，但服务端已经不认这把 access token
    final newAccess = jwt({'name': '李四', 'exp': 2000000000});
    adapter.newAccess = newAccess;
    await AiAccountRepository.instance.upsert(
      AiAccount(
        id: 'a1',
        providerId: 'pRaccoon',
        accessToken: 'old-access',
        refreshToken: 'refresh-1',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        uid: 'u1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  });

  tearDown(() {
  });

  test('聊天 401 → 刷新 token → 用新凭证重发并成功', () async {
    final reply = await service.chatResponse([
      ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now()),
    ]);

    expect(reply.content, 'ok');
    expect(adapter.chatAuthHeaders, ['Bearer old-access', 'Bearer ${adapter.newAccess}']);
    expect(adapter.refreshCount, 1);
  });
}

class _AuthRetryAdapter implements HttpClientAdapter {
  String newAccess = '';
  int refreshCount = 0;
  final List<String> chatAuthHeaders = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/auth/v1/refresh')) {
      refreshCount++;
      return _json({
        'data': {'access_token': newAccess, 'refresh_token': 'refresh-2'},
      });
    }
    if (path.endsWith('/auth/v1/user_info')) {
      return _json({
        'data': {'phone': '13800138000'},
      });
    }
    if (path.endsWith('/llm/v2/chat/completions')) {
      final auth = _header(options.headers, 'authorization');
      chatAuthHeaders.add(auth);
      if (auth == 'Bearer old-access') {
        return _json({'error': {'message': 'expired'}}, status: 401);
      }
      return _json({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'ok'},
          },
        ],
        'usage': {
          'prompt_tokens': 1,
          'completion_tokens': 1,
          'total_tokens': 2,
        },
      });
    }
    return _json({'message': 'unexpected path $path'}, status: 404);
  }

  ResponseBody _json(Map<String, dynamic> body, {int status = 200}) {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
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