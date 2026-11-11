import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 思考强度落到请求体的回归测试（假 adapter，不联网）
///
/// 能力表只决定「支持哪些档位」，真正发什么字段由这里锁定：不同厂商的
/// 参数名一旦写错，用户调了档位也不会生效，甚至被网关 400。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _BodyRecordingAdapter adapter;
  late AiService service;

  AiConfig config(
    String modelName, {
    String provider = 'openai',
    String? vendorId,
    ReasoningEffort? effort,
    List<ReasoningEffort>? efforts,
  }) {
    return AiConfig(
      providerId: 'provider-1',
      name: 'demo',
      provider: provider,
      modelName: modelName,
      apiKey: 'sk-test-00000000',
      baseUrl: provider == 'gemini'
          ? 'https://generativelanguage.googleapis.com'
          : 'https://gw.example.com/v1',
      vendorId: vendorId,
      reasoningEffort: effort,
      reasoningEfforts: efforts,
    );
  }

  Future<String> send(AiConfig config) {
    service.updateConfig(config);
    return service.chat([
      ChatMessage(role: 'user', content: 'hi', timestamp: DateTime.now()),
    ]);
  }

  Map<String, dynamic> lastBody() =>
      Map<String, dynamic>.from(adapter.bodies.last as Map);

  setUp(() {
    adapter = _BodyRecordingAdapter();
    service = AiService();
    service.httpClientAdapterForTest = adapter;
  });

  test('OpenAI 系写 reasoning_effort', () async {
    await send(config('gpt-5.4-mini', effort: ReasoningEffort.high));

    expect(lastBody()['reasoning_effort'], 'high');
  });

  test('none 档映射为 minimal', () async {
    await send(config('gpt-5.4-mini', effort: ReasoningEffort.none));

    expect(lastBody()['reasoning_effort'], 'minimal');
  });

  test('GLM 写 thinking.type 开关，并附带 reasoning_effort', () async {
    await send(
      config('glm-4.6', vendorId: 'zhipu', effort: ReasoningEffort.medium),
    );

    final body = lastBody();
    expect(body['thinking'], {'type': 'enabled'});
    expect(body['reasoning_effort'], 'medium');
  });

  test('GLM 自定义的 xhigh 也真实发出', () async {
    await send(
      config(
        'glm-4.6',
        vendorId: 'zhipu',
        effort: ReasoningEffort.xhigh,
        efforts: [ReasoningEffort.xhigh],
      ),
    );

    final body = lastBody();
    expect(body['thinking'], {'type': 'enabled'});
    expect(body['reasoning_effort'], 'xhigh');
  });

  test('Qwen 写 enable_thinking 与预算', () async {
    await send(config('qwen3-max', effort: ReasoningEffort.high));

    final body = lastBody();
    expect(body['enable_thinking'], isTrue);
    expect(body['thinking_budget'], 16384);
  });

  test('未收录模型按通用 reasoning_effort 发送（选了就生效）', () async {
    await send(config('my-custom-model', effort: ReasoningEffort.high));

    final body = lastBody();
    expect(body['reasoning_effort'], 'high');
    expect(body.containsKey('thinking'), isFalse);
    expect(body.containsKey('enable_thinking'), isFalse);
  });

  test('自定义勾选的 xhigh 会真实发出', () async {
    await send(
      config(
        'gpt-5.4-mini',
        effort: ReasoningEffort.xhigh,
        efforts: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
      ),
    );

    expect(lastBody()['reasoning_effort'], 'xhigh');
  });

  test('自动识别之外的档位没有自定义时静默跳过', () async {
    await send(config('gpt-5.4-mini', effort: ReasoningEffort.xhigh));

    expect(lastBody().containsKey('reasoning_effort'), isFalse);
  });

  test('自定义 max 档在 Qwen 里发更大的思考预算', () async {
    await send(
      config(
        'qwen3-max',
        effort: ReasoningEffort.max,
        efforts: [ReasoningEffort.max],
      ),
    );

    final body = lastBody();
    expect(body['enable_thinking'], isTrue);
    expect(body['thinking_budget'], 65536);
  });

  test('未收录模型的关闭档写 minimal（时间线提取默认值）', () async {
    await send(config('my-custom-model', effort: ReasoningEffort.none));

    expect(lastBody()['reasoning_effort'], 'minimal');
  });

  test('模型不支持的档位静默跳过', () async {
    // Gemini 3 默认只有低/高，medium 没有自定义时不应发出
    await send(
      config(
        'gemini-3-flash-preview',
        provider: 'gemini',
        effort: ReasoningEffort.medium,
      ),
    );

    final generationConfig = lastBody()['generationConfig'] as Map;
    expect(generationConfig.containsKey('thinkingConfig'), isFalse);
  });

  test('Gemini 3 写 generationConfig.thinkingConfig.thinkingLevel', () async {
    await send(
      config(
        'gemini-3-flash-preview',
        provider: 'gemini',
        effort: ReasoningEffort.high,
      ),
    );

    final generationConfig = lastBody()['generationConfig'] as Map;
    expect(generationConfig['thinkingConfig'], {'thinkingLevel': 'high'});
  });

  test('网关 400 点名思考参数时关掉参数原地重发', () async {
    adapter.failWith(
      statusCode: 400,
      body: '{"error":{"message":"Unsupported parameter: reasoning_effort"}}',
      failFirst: 1,
    );

    final reply = await send(
      config('gpt-5.4-mini', effort: ReasoningEffort.high),
    );

    expect(reply, 'ok');
    expect(adapter.bodies.length, 2, reason: '应原地重发一次');
    expect(
      (adapter.bodies.first as Map).containsKey('reasoning_effort'),
      isTrue,
    );
    expect(
      (adapter.bodies.last as Map).containsKey('reasoning_effort'),
      isFalse,
      reason: '重发时不能再带被拒绝的参数',
    );
  });

  test('与思考无关的 400 不触发降级（重试仍带参数）', () async {
    adapter.failWith(
      statusCode: 400,
      body: '{"error":{"message":"invalid model"}}',
      failFirst: 1,
    );

    final reply = await send(
      config('gpt-5.4-mini', effort: ReasoningEffort.high),
    );

    expect(reply, 'ok');
    expect(adapter.bodies.length, greaterThanOrEqualTo(2));
    expect(
      (adapter.bodies.last as Map).containsKey('reasoning_effort'),
      isTrue,
      reason: '错误没点名思考字段，不能误判成端点不支持',
    );
  });
}

class _BodyRecordingAdapter implements HttpClientAdapter {
  final List<dynamic> bodies = [];
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
    bodies.add(options.data);

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

    final gemini = options.path.contains('generativelanguage');
    final ok = gemini
        ? '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
        : '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
              '"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}';
    return ResponseBody.fromString(
      ok,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
