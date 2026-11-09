import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_route_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 路由组「成员失败自动切换」的回归测试
///
/// 用假 adapter 断言真实发出的 URL / model / Authorization 是否落到了下一个成员，
/// 以及「正文已输出后绝不换成员重发」这条硬约束。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 1, 1);
  late _RecordingAdapter adapter;
  late AiService service;

  AiProvider provider(String id, String model) => AiProvider(
        id: id,
        name: id,
        providerType: 'openai',
        baseUrl: 'https://$id.example.com/v1',
        apiKeys: ['sk-$id-key'],
        models: [AiProviderModel.of(model)],
        createdAt: now,
        updatedAt: now,
      );

  AiConfig configFor(AiProvider p) =>
      AiConfig.fromProvider(p, p.models.first.id);

  setUp(() {
    ApiKeyPool.instance.resetForTest();
    AiRouteService.instance.resetForTest();
    adapter = _RecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
    // 每个厂商只有一把 Key：Key 级轮询无路可走，只剩「换成员」这一条退路
    AiService.providerKeysLoaderForTest = (id) async => ['sk-$id-key'];
  });

  tearDown(() {
    AiService.providerKeysLoaderForTest = null;
  });

  List<ChatMessage> messages() => [
        ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now()),
      ];

  test('成员 A 被限流：同一条请求自动切到成员 B，URL/模型/凭证全部换成 B 的', () async {
    final providerA = provider('pA', 'a1');
    final providerB = provider('pB', 'b1');
    final group = AiRouteGroup(
      id: 'g1',
      name: '主模型池',
      strategy: RouteStrategy.rotate,
      members: const [
        RouteGroupMember(providerId: 'pA', modelName: 'a1'),
        RouteGroupMember(providerId: 'pB', modelName: 'b1'),
      ],
      createdAt: now,
      updatedAt: now,
    );
    final selection =
        AiRouteService.instance.select(group, [providerA, providerB]);
    expect(selection.config.modelName, 'a1');

    service.updateConfig(selection.config);
    // 成员 A 的重试预算为 4 次（首次 + 3 次退避重试），全部 429 之后才让位给成员 B
    adapter.failWith(statusCode: 429, body: '{"error":{"message":"rate limit"}}', failFirst: 4);

    final reply = await service.chatResponse(
      messages(),
      route: selection.toRoute(),
    );

    expect(reply.content, 'ok');
    expect(adapter.uris.length, 5);
    expect(adapter.uris.take(4), everyElement(
      'https://pa.example.com/v1/chat/completions',
    ));
    expect(adapter.uris.last, 'https://pb.example.com/v1/chat/completions');
    expect(adapter.models.take(4), everyElement('a1'));
    expect(adapter.models.last, 'b1');
    expect(adapter.authHeaders.take(4), everyElement('Bearer sk-pA-key'));
    expect(
      adapter.authHeaders.last,
      'Bearer sk-pB-key',
      reason: '切到成员 B 后必须带上 B 自己的 Key，不能沿用 A 的全局 header',
    );
  });

  test('未绑定路由组时不发生任何成员切换（行为与改动前一致）', () async {
    final providerA = provider('pA', 'a1');
    service.updateConfig(configFor(providerA));
    adapter.failWith(statusCode: 429, body: '{"error":{"message":"rate limit"}}', failFirst: 5);

    await expectLater(
      service.chatResponse(messages()),
      throwsA(isA<DioException>()),
    );

    // 首次 + 3 次通用重试（单 Key 厂商）后放弃，不会跑到别的地址去
    expect(adapter.uris.length, 4);
    expect(
      adapter.uris,
      everyElement('https://pa.example.com/v1/chat/completions'),
    );
  });

  test('正文已输出后绝不换成员重发（避免同一条回答由两个模型各说一遍）', () async {
    final providerA = provider('pA', 'a1');
    final providerB = provider('pB', 'b1');
    final group = AiRouteGroup(
      id: 'g1',
      name: '主模型池',
      strategy: RouteStrategy.rotate,
      members: const [
        RouteGroupMember(providerId: 'pA', modelName: 'a1'),
        RouteGroupMember(providerId: 'pB', modelName: 'b1'),
      ],
      createdAt: now,
      updatedAt: now,
    );
    final selection =
        AiRouteService.instance.select(group, [providerA, providerB]);
    service.updateConfig(selection.config);
    // 先吐一段正文，再以流内 error 对象收尾
    adapter.sseBody = 'data: {"choices":[{"delta":{"content":"部分回答"}}]}\n\n'
        'data: {"error":{"message":"rate limit"}}\n\n';

    final chunks = <String>[];
    await expectLater(
      service
          .chatStreamWithTools(
            messages: messages(),
            route: selection.toRoute(),
          )
          .map((c) => c.text ?? '')
          .where((t) => t.isNotEmpty)
          .forEach(chunks.add),
      throwsA(isA<Exception>()),
    );

    expect(chunks.join(), '部分回答');
    expect(
      adapter.uris.length,
      1,
      reason: '正文已交付就禁止重发：换成员会让用户看到两段拼接的回答',
    );
  });

  test('流式请求下成员 A 首包前失败，会自动切到成员 B 完成本次回答', () async {
    final providerA = provider('pA', 'a1');
    final providerB = provider('pB', 'b1');
    final group = AiRouteGroup(
      id: 'g1',
      name: '主模型池',
      strategy: RouteStrategy.rotate,
      members: const [
        RouteGroupMember(providerId: 'pA', modelName: 'a1'),
        RouteGroupMember(providerId: 'pB', modelName: 'b1'),
      ],
      createdAt: now,
      updatedAt: now,
    );
    final selection =
        AiRouteService.instance.select(group, [providerA, providerB]);
    service.updateConfig(selection.config);
    adapter.failWith(statusCode: 429, body: '{"error":{"message":"rate limit"}}', failFirst: 4);
    // 同一条用户消息里 AgentLoop 会多次调用发信方法：共用一个 route 实例
    final route = selection.toRoute();

    final chunks = <String>[];
    await for (final chunk
        in service.chatStreamWithTools(messages: messages(), route: route)) {
      if (chunk.text != null && chunk.text!.isNotEmpty) chunks.add(chunk.text!);
    }

    expect(chunks.join(), 'hello');
    expect(adapter.uris.last, 'https://pb.example.com/v1/chat/completions');
    expect(adapter.authHeaders.last, 'Bearer sk-pB-key');

    // 下一步工具循环沿用已切换到的成员 B：不能每一步都从失败过的 A 重新开头
    chunks.clear();
    await for (final chunk
        in service.chatStreamWithTools(messages: messages(), route: route)) {
      if (chunk.text != null && chunk.text!.isNotEmpty) chunks.add(chunk.text!);
    }
    expect(chunks.join(), 'hello');
    expect(adapter.uris.last, 'https://pb.example.com/v1/chat/completions');
    expect(
      adapter.uris.length,
      6,
      reason: '第二次请求应直接发给 B（无需再重试 A）',
    );
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<String> uris = [];
  final List<String> models = [];
  final List<String> authHeaders = [];

  /// 流式响应体（非空时按 SSE 返回）
  String sseBody = 'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'
      'data: [DONE]\n\n';

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
    uris.add(options.uri.toString());
    authHeaders.add(_header(options.headers, 'authorization'));

    final data = options.data;
    if (data is Map && data['model'] != null) {
      models.add(data['model'].toString());
    }

    final failing = _failStatus != null && _calls <= _failFirst;
    if (failing) {
      return ResponseBody.fromString(
        _failBody,
        _failStatus!,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    final streaming = options.responseType == ResponseType.stream;
    if (streaming) {
      return ResponseBody.fromString(
        sseBody,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );
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
      if (entry.key.toLowerCase() == name) return entry.value?.toString() ?? '';
    }
    return '';
  }
}

const String _okBody = '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
    '"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}';
