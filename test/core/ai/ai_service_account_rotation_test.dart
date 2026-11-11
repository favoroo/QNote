import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/raccoon_account_router.dart';
import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 多账号发信闭环：撞限流换号重发、轮换策略与会话亲和生效
///
/// 账号列表走 `accountsLoaderForTest` 注入（不搭 sqflite）：选号逻辑本身是纯内存的，
/// 这里要锁的是「发信层是否真的按选号结果换 header」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MultiAccountAdapter adapter;
  late AiService service;
  final auth = RaccoonAuthService.instance;

  AiProvider provider({
    String routing = AiProvider.defaultAccountRouting,
    String affinity = AiProvider.defaultAccountAffinity,
  }) {
    return AiProvider(
      id: 'pRaccoon',
      vendorId: 'raccoon',
      name: '商汤小浣熊',
      providerType: 'openai',
      baseUrl: 'https://xiaohuanxiong.com/api/web/llm/v2',
      authMode: AiProvider.authModeRaccoon,
      accountRouting: routing,
      accountAffinity: affinity,
      apiKeys: const [],
      models: const [AiProviderModel(id: 'raccoon-chat-ml-5-5', name: 'Raccoon Chat')],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  AiAccount account(String id, int order) {
    return AiAccount(
      id: id,
      providerId: 'pRaccoon',
      accessToken: 'token-$id',
      refreshToken: 'refresh-$id',
      // 新鲜凭证：不触发刷新链路，请求直接打到 adapter
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      uid: id,
      sortOrder: order,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  List<ChatMessage> messages(String text) => [ChatMessage(role: 'user', content: text, timestamp: DateTime.now())];

  setUpAll(() {
    // AI 日志会落持久化通道，不 mock 会刷一屏 MissingPluginException
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() {
    auth.resetForTest();
    adapter = _MultiAccountAdapter();
    auth.httpClientAdapterForTest = adapter;
    service = AiService();
    service.httpClientAdapterForTest = adapter;
  });

  tearDown(auth.resetForTest);

  test('轮流：两个账号各用一次，Authorization 跟着换', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account('a1', 0), account('a2', 1)];
    service.updateConfig(AiConfig.fromProvider(provider(), 'raccoon-chat-ml-5-5'));

    await service.chatResponse(messages('hi'));
    await service.chatResponse(messages('hi again'));

    expect(adapter.authHeaders, ['Bearer token-a1', 'Bearer token-a2']);
  });

  test('账号 A 撞 429 → 自动换账号 B 重发并成功', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account('a1', 0), account('a2', 1)];
    adapter.rateLimitedTokens = {'token-a1'};
    service.updateConfig(AiConfig.fromProvider(provider(), 'raccoon-chat-ml-5-5'));

    final reply = await service.chatResponse(messages('hi'));

    expect(reply.content, 'ok');
    expect(adapter.authHeaders, ['Bearer token-a1', 'Bearer token-a2']);
  });

  test('单账号撞 429 时不换号：沿用原有退避重试链路并透出原始错误', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account('a1', 0)];
    adapter.rateLimitedTokens = {'token-a1'};
    service.updateConfig(AiConfig.fromProvider(provider(), 'raccoon-chat-ml-5-5'));

    await expectLater(service.chatResponse(messages('hi')), throwsA(isA<DioException>()));
    // 退避重试仍打在同一账号上，没有把唯一账号打进冷却而误报「请重新登录」
    expect(adapter.authHeaders, isNotEmpty);
    expect(adapter.authHeaders.every((h) => h == 'Bearer token-a1'), isTrue);
    expect(auth.isAccountCooling('a1'), isFalse);
  });

  test('会话亲和：同一会话的两条消息固定用同一账号', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account('a1', 0), account('a2', 1)];
    final scoped = provider(affinity: AccountAffinity.session.id);
    service.updateConfig(AiConfig.fromProvider(scoped, 'raccoon-chat-ml-5-5'));

    await service.chatResponse(
      messages('hi'),
      scope: const AiRequestScope(sessionKey: 'chat:s1', turnKey: 'chat:s1:1'),
    );
    await service.chatResponse(
      messages('again'),
      scope: const AiRequestScope(sessionKey: 'chat:s1', turnKey: 'chat:s1:2'),
    );

    expect(adapter.authHeaders, ['Bearer token-a1', 'Bearer token-a1']);
  });

  test('顺序策略：始终用排在前面的账号', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account('a1', 0), account('a2', 0)];
    final failover = provider(routing: AccountRouting.failover.id);
    service.updateConfig(AiConfig.fromProvider(failover, 'raccoon-chat-ml-5-5'));

    await service.chatResponse(messages('hi'));
    await service.chatResponse(messages('again'));

    expect(adapter.authHeaders, ['Bearer token-a1', 'Bearer token-a1']);
  });

  test('严格亲和：账号失败也不换号，错误直接抛给用户', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account('a1', 0), account('a2', 1)];
    adapter.rateLimitedTokens = {'token-a1'};
    final strict = provider(affinity: AccountAffinity.strict.id);
    service.updateConfig(AiConfig.fromProvider(strict, 'raccoon-chat-ml-5-5'));

    await expectLater(
      service.chatResponse(
        messages('hi'),
        scope: const AiRequestScope(sessionKey: 'chat:s1', turnKey: 'chat:s1:1'),
      ),
      throwsA(isA<DioException>()),
    );
    // 只打过 a1，从未换到 a2
    expect(adapter.authHeaders.every((h) => h == 'Bearer token-a1'), isTrue);
  });

  test('停用的账号不参与轮换', () async {
    RaccoonAuthService.accountsLoaderForTest = (_) async => [
      account('a1', 0).copyWith(enabled: false),
      account('a2', 1),
    ];
    final failover = provider(routing: AccountRouting.failover.id);
    service.updateConfig(AiConfig.fromProvider(failover, 'raccoon-chat-ml-5-5'));

    await service.chatResponse(messages('hi'));

    expect(adapter.authHeaders, ['Bearer token-a2']);
  });
}

class _MultiAccountAdapter implements HttpClientAdapter {
  final List<String> authHeaders = [];

  /// 这些 token 的请求返回 429（模拟账号被限流）
  Set<String> rateLimitedTokens = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final auth = _header(options.headers, 'authorization');
    if (options.uri.path.endsWith('/chat/completions')) {
      authHeaders.add(auth);
      if (rateLimitedTokens.contains(auth.replaceFirst('Bearer ', ''))) {
        return _json({
          'error': {'message': 'rate limit exceeded'},
        }, status: 429);
      }
      return _json({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'ok'},
          },
        ],
      });
    }
    return _json({'message': 'unexpected path ${options.uri.path}'}, status: 404);
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
