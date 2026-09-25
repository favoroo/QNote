import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 记录每轮实际发给模型的 messages，用来验证图片有没有在发请求前被剥掉
class _RecordingAiService extends AiService {
  final List<List<ChatMessage>> captured = [];

  @override
  Stream<AiToolStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
    void Function(Duration hold)? onQuotaHold,
    void Function()? onStreamRetry,
    CancelToken? cancelToken,
  }) async* {
    captured.add(List.of(messages));
    yield const AiToolStreamChunk.text('好的');
  }

  /// 展平所有轮次里的消息，便于按内容查找
  List<ChatMessage> get allSent => [for (final turn in captured) ...turn];
}

ChatMessage _userWithImages(List<String> images, {String content = '这张图里是什么？'}) =>
    ChatMessage(role: 'user', content: content, images: images);

Future<List<List<ChatMessage>>> _runOnce({required bool supportsImageInput}) async {
  final service = _RecordingAiService();
  final loop = AgentLoop(
    aiService: service,
    dispatcher: ToolDispatcher(),
    supportsImageInput: supportsImageInput,
  );
  await for (final _ in loop.run(
    conversationHistory: [
      _userWithImages([
        '/images/photo-1.jpg',
        'data:image/jpeg;base64,QUFBQlVCQllCRQ',
      ]),
    ],
    systemPrompt: '你是小Q',
  )) {
    // 事件本身不在本用例关注范围内，跑完即可
  }
  return service.captured;
}

void main() {
  // LoggerService 落盘要读 SharedPreferences，binding 未初始化时会打印告警
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AgentLoop 按模型能力事前剥离图片', () {
    test('模型不支持图片输入时，发给模型的消息一张图都没有', () async {
      final captured = await _runOnce(supportsImageInput: false);

      expect(captured, isNotEmpty, reason: '至少发过一轮请求');
      for (final message in captured.first) {
        expect(
          message.images == null || message.images!.isEmpty,
          isTrue,
          reason: '不支持图片输入的模型不应收到任何图片',
        );
      }
    });

    test('剥离后原文照留，并追加指向 describe_image 的引导', () async {
      final captured = await _runOnce(supportsImageInput: false);
      final user = captured.first.firstWhere((m) => m.content.contains('这张图里是什么'));

      expect(user.content, contains('这张图里是什么？'), reason: '用户原话一个字都不能改');
      expect(user.content, contains('describe_image'));
      expect(user.content, contains('/images/photo-1.jpg'),
          reason: '要给出能回传给工具的图片标识');
      expect(user.content, contains('内联图片'));
      expect(user.content, contains('严禁'));
    });

    test('内联图片的 base64 不会被当成路径回传给模型', () async {
      final captured = await _runOnce(supportsImageInput: false);

      expect(
        captured.first.any((m) => m.content.contains('QUFBQlVCQllCRQ')),
        isFalse,
        reason: '把几百 KB 的 base64 写进正文既烧上下文，也没法指望模型原样回传',
      );
    });

    test('模型支持图片输入时，图片按原样保留', () async {
      final captured = await _runOnce(supportsImageInput: true);
      final user = captured.first.firstWhere((m) => m.role == 'user');

      expect(user.images, hasLength(2));
      expect(user.content, '这张图里是什么？', reason: '能看图时不该追加任何剥离说明');
    });
  });

  group('工具回显图片的注入分支', () {
    test('模型不支持图片输入时，view_image 注入的合成消息也换成文字引导', () async {
      final service = _RecordingAiService();
      final loop = AgentLoop(
        aiService: service,
        dispatcher: ToolDispatcher(),
        supportsImageInput: false,
      );
      // 预置一条 view_image 的注入消息（模拟历史上已注入的图片），走首轮剥离
      await for (final _ in loop.run(
        conversationHistory: [
          ChatMessage(
            role: 'user',
            content: '[系统注入] 工具 view_image 的结果附带 1 张图片（来源: /images/x.jpg）。'
                '图片已附加在本条消息中，请直接基于图片画面内容继续分析。',
            images: const ['data:image/jpeg;base64,QUFBQlVCQllCRQ'],
          ),
        ],
        systemPrompt: '你是小Q',
      )) {}

      final injected = service.allSent
          .firstWhere((m) => m.content.startsWith('[系统注入]'));
      expect(injected.images == null || injected.images!.isEmpty, isTrue);
      expect(injected.content, contains('describe_image'));
      expect(injected.content, isNot(contains('请直接基于图片画面内容')));
    });
  });
}
