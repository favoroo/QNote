import 'dart:convert';
import 'dart:io';
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

/// 流式**中途被掐断**的可重试边界。
///
/// 现场：内置池跑 AgentLoop 第 9 轮（51 条消息 + 14 个工具），商汤网关在响应体
/// 还没读完时关掉 TCP，dart:io 抛 `HttpException: Connection closed while receiving data`。
/// 该异常不经 Dio 包装（`ResponseType.stream` 下 body 由我们自己 `await for`），
/// 而旧的重试判据是「流出去过任何东西就不重发」—— 推理模型的光吐思考阶段最长，
/// 一次掐流就把整条任务连同前 8 轮工具成果一起判死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late Database db;
  late _ScriptedAdapter adapter;
  late AiService service;

  AiConfig poolConfig() => AiConfig(
        id: 'free_glm-5.2',
        name: 'GLM 5.2',
        provider: 'openai',
        modelName: 'glm-5.2',
        apiKey: BuiltinFreeKeys.getDecryptedKeys().first,
        baseUrl: 'https://token.sensenova.cn/v1',
        vendorId: 'free_model',
        createdAt: DateTime(2026, 9, 25),
        updatedAt: DateTime(2026, 9, 25),
      );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    FreeModelKeyManager.instance.resetForTest();
    SensenovaQuotaPolicy.resetToDefaults();
    service = AiService();
    adapter = _ScriptedAdapter([]);
    service.httpClientAdapterForTest = adapter;
    await db.delete(AiRequestStatsRepository.table);
  });

  group('掐流后重发的边界', () {
    test('只吐过思考就被掐断：原地重发一次，正文只来自第二次', () async {
      adapter.scripts = [
        _SseScript(frames: [_reasoning('旧的一段思考')], cut: _closed()),
        _SseScript(frames: [_reasoning('新的一段思考'), _text('最终回答'), _done]),
      ];
      service.updateConfig(poolConfig(), maxTokens: 32000);

      final chunks = await service
          .chatStreamWithTools(messages: [ChatMessage(role: 'user', content: '写点东西')])
          .toList();

      expect(adapter.callCount, equals(2), reason: '思考阶段断流必须重发，不能整条任务判死');
      expect(
        chunks.map((c) => c.reasoningText).whereType<String>().toList(),
        equals(['旧的一段思考', '新的一段思考']),
        reason: 'AiService 这层只负责重发，去重由消费方看到 onStreamRetry 后复位完成',
      );
      expect(
        chunks.map((c) => c.text).whereType<String>().toList(),
        equals(['最终回答']),
      );
    });

    test('重发前回调 onStreamRetry，且只在真的重发时回调', () async {
      adapter.scripts = [
        _SseScript(frames: [_reasoning('半截')], cut: _closed()),
        _SseScript(frames: [_text('回答'), _done]),
      ];
      service.updateConfig(poolConfig());

      final notified = <int>[];
      await service
          .chatStreamWithTools(
            messages: [ChatMessage(role: 'user', content: 'hi')],
            onStreamRetry: () => notified.add(adapter.callCount),
          )
          .toList();

      // 回调发生在第一次请求已失败、第二次尚未发出之时：上层据此作废旧碎片
      expect(notified, equals([1]));
    });

    test('正文已经流出后再掐断：不重发，原样把已交付的内容留在异常之外', () async {
      adapter.scripts = [
        _SseScript(frames: [_text('已经给用户看了一半')], cut: _closed()),
        _SseScript(frames: [_text('重复的回答'), _done]),
      ];
      service.updateConfig(poolConfig());

      final collected = <String>[];
      await expectLater(
        service
            .chatStreamWithTools(messages: [ChatMessage(role: 'user', content: 'hi')])
            .forEach((chunk) {
          if (chunk.text != null) collected.add(chunk.text!);
        }),
        throwsA(isA<Exception>()),
      );

      expect(adapter.callCount, equals(1), reason: '重发会得到两段首尾相接的回答，比失败更糟');
      expect(collected, equals(['已经给用户看了一半']));
    });

    test('工具参数生成阶段被掐断：也算未交付，重发且通知复位', () async {
      adapter.scripts = [
        _SseScript(frames: [_toolArgs('write_file', '{"path": "/notes/a.md')], cut: _closed()),
        _SseScript(frames: [_toolArgs('write_file', '{"path": "/notes/a.md"}'), _done]),
      ];
      service.updateConfig(poolConfig());

      var notified = 0;
      final progress = <String>[];
      await service
          .chatStreamWithTools(
            messages: [ChatMessage(role: 'user', content: '记一笔')],
            onStreamRetry: () => notified++,
            onToolCallsReady: (_) {},
          )
          .forEach((chunk) {
            if (chunk.toolProgress != null) progress.add(chunk.toolProgress!.toolName);
          });

      expect(adapter.callCount, equals(2));
      expect(notified, equals(1));
      expect(progress, equals(['write_file', 'write_file']));
    });

    test('每次重发都换一把 Key，且掐流不进限流分布但会留一行观测', () async {
      adapter.scripts = [
        _SseScript(frames: [_reasoning('半截')], cut: _closed()),
        _SseScript(frames: [_text('回答'), _done]),
      ];
      service.updateConfig(poolConfig());

      await service
          .chatStreamWithTools(messages: [ChatMessage(role: 'user', content: 'hi')])
          .drain<void>();
      await service.flushRequestStatsForTest();

      expect(adapter.authHeaders.toSet().length, equals(2), reason: '重试必须换新 Key');
      final rows = await AiRequestStatsRepository().all();
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.outcome).toList()..sort(),
        equals([AiRequestOutcomes.ok, AiRequestOutcomes.other]),
        reason: '掐流属连接层故障：记一行 other 让诊断卡看得见，但不按限流归因',
      );
      expect(
        rows.every((r) => r.httpStatus == null),
        isTrue,
        reason: '连接被提前关闭时没有可归因的状态码',
      );
    });
  });
}

const String _done = 'data: [DONE]\n\n';

/// 网关侧「连接被提前关闭」的真实形态：dart:io 的 HttpException（不是 DioException）
Object _closed() => const HttpException('Connection closed while receiving data');

String _reasoning(String text) =>
    'data: ${jsonEncode({'choices': [
      {'delta': {'reasoning_content': text}},
    ]})}\n\n';

String _text(String text) =>
    'data: ${jsonEncode({
        'choices': [
          {'delta': {'content': text}},
        ],
      })}\n\n';

String _toolArgs(String name, String partialArgs) =>
    'data: ${jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_1',
                  'function': {'name': name, 'arguments': partialArgs},
                },
              ],
            },
          },
        ],
      })}\n\n';

/// 一次请求的剧本：先送 SSE 帧，再决定是收流还是被掐断
class _SseScript {
  const _SseScript({required this.frames, this.cut});

  final List<String> frames;

  /// 送完 [frames] 后抛出的异常，null 表示正常收到 [DONE] 收尾
  final Object? cut;
}

/// 按剧本逐帧吐流、必要时中途抛错的假 adapter
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.scripts);

  List<_SseScript> scripts;
  final List<String> authHeaders = [];
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authHeaders.add(_findHeader(options.headers, 'authorization'));
    final script = scripts[callCount.clamp(0, scripts.length - 1)];
    callCount++;
    return ResponseBody(
      _play(script),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  /// 逐帧一个 data 事件，保证服务端的收流语义（每帧独立到达）被如实模拟
  static Stream<Uint8List> _play(_SseScript script) async* {
    for (final frame in script.frames) {
      yield Uint8List.fromList(utf8.encode(frame));
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (script.cut != null) throw script.cut!;
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
