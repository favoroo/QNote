import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/core/agent/engine/agent_cancellation_token.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/grep_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/list_dir_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/read_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/write_file_tool.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';

// 用于测试的 Mock AiService
class MockAiService extends AiService {
  final List<String> textDeltas;
  final List<ToolCall> returnToolCalls;

  /// 模拟的工具参数流式生成进度片段（在正文前依次吐出）
  final List<ToolCallProgress> progressChunks;

  MockAiService({
    this.textDeltas = const ['测试回答'],
    this.returnToolCalls = const [],
    this.progressChunks = const [],
  });

  @override
  Stream<AiToolStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
    CancelToken? cancelToken,
  }) async* {
    for (final progress in progressChunks) {
      yield AiToolStreamChunk.toolProgress(progress);
    }
    for (final delta in textDeltas) {
      yield AiToolStreamChunk.text(delta);
    }
    if (returnToolCalls.isNotEmpty) {
      onToolCallsReady?.call(returnToolCalls);
    }
  }
}

// 首包后挂起并模拟请求被中止断连的 AiService 桩
class MidStreamCancelAiService extends AiService {
  @override
  Stream<AiToolStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
    CancelToken? cancelToken,
  }) async* {
    yield const AiToolStreamChunk.text('第一段');
    // 模拟用户点停止后 Dio CancelToken 断连：流挂起片刻后抛出取消异常
    await Future<void>.delayed(const Duration(milliseconds: 20));
    throw Exception('请求已被用户取消');
  }
}

void main() {
  group('Pi-Agent 对齐架构能力测试', () {
    test('1. AgentCancellationToken 触发与监听', () {
      final token = AgentCancellationToken();
      expect(token.isCancelled, false);
      expect(token.reason, isNull);

      int listenerFired = 0;
      token.addListener(() {
        listenerFired++;
      });

      token.cancel('测试中止');
      expect(token.isCancelled, true);
      expect(token.reason, '测试中止');
      expect(listenerFired, 1);

      // 再次 cancel 幂等安全
      token.cancel('重复中止');
      expect(token.reason, '测试中止');
      expect(listenerFired, 1);
    });

    test('2. 只读工具与写工具 ExecutionMode 正确区分', () {
      final readFile = ReadFileTool();
      final listDir = ListDirTool();
      final grep = GrepTool();
      final writeFile = WriteFileTool();

      expect(readFile.executionMode, ToolExecutionMode.parallel);
      expect(listDir.executionMode, ToolExecutionMode.parallel);
      expect(grep.executionMode, ToolExecutionMode.parallel);
      expect(writeFile.executionMode, ToolExecutionMode.sequential);
    });

    test('3. AgentLoop 生命周期事件流与 Hooks 钩子验证', () async {
      final mockAi = MockAiService(textDeltas: ['完成啦']);
      final dispatcher = ToolDispatcher();

      bool beforeHookCalled = false;
      bool afterHookCalled = false;

      final loop = AgentLoop(
        aiService: mockAi,
        dispatcher: dispatcher,
        beforeToolCall: (_) async => beforeHookCalled = true,
        afterToolCall: (_, __) async => afterHookCalled = true,
      );

      final events = <AgentEventType>[];
      await for (final event in loop.run(
        conversationHistory: [],
        systemPrompt: '测试系统提示词',
      )) {
        events.add(event.type);
      }

      expect(events, contains(AgentEventType.agentStart));
      expect(events, contains(AgentEventType.turnStart));
      expect(events, contains(AgentEventType.contentDelta));
      expect(events, contains(AgentEventType.turnEnd));
      expect(events, contains(AgentEventType.finished));
      expect(events, contains(AgentEventType.agentEnd));
      expect(beforeHookCalled, false); // 本轮没有工具调用
      expect(afterHookCalled, false);
    });

    test('4. AgentLoop 动态取消检测', () async {
      final token = AgentCancellationToken();
      token.cancel('用户立刻点击取消');

      final mockAi = MockAiService(textDeltas: ['文字']);
      final dispatcher = ToolDispatcher();
      final loop = AgentLoop(aiService: mockAi, dispatcher: dispatcher);

      final events = <AgentEventType>[];
      await for (final event in loop.run(
        conversationHistory: [],
        systemPrompt: '系统提示词',
        cancellationToken: token,
      )) {
        events.add(event.type);
      }

      expect(events, contains(AgentEventType.agentStart));
      expect(events, contains(AgentEventType.finished));
      expect(events, contains(AgentEventType.agentEnd));
      expect(events.contains(AgentEventType.turnStart), false); // 提前中止未开始第 1 轮
    });

    test('5. 流式进行中点击中止 → 立即优雅终止且不作为错误上报', () async {
      final token = AgentCancellationToken();
      final mockAi = MidStreamCancelAiService();
      final dispatcher = ToolDispatcher();
      final loop = AgentLoop(aiService: mockAi, dispatcher: dispatcher);

      final events = <AgentEventType>[];
      await for (final event in loop.run(
        conversationHistory: [],
        systemPrompt: '系统提示词',
        cancellationToken: token,
      )) {
        events.add(event.type);
        // 模拟用户在收到首个正文增量时点击停止
        if (event.type == AgentEventType.contentDelta && !token.isCancelled) {
          token.cancel('用户主动中止操作');
        }
      }

      expect(events, contains(AgentEventType.finished));
      expect(events, contains(AgentEventType.agentEnd));
      // 中止属于正常收尾：绝不允许出现 error 事件（否则 UI 会显示"发生错误"）
      expect(events.contains(AgentEventType.error), false);
    });

    test('6. 工具参数流式生成进度 → toolCalling 事件（提取详情并去重）', () async {
      final mockAi = MockAiService(
        progressChunks: const [
          // path 已流出：应产出 toolCalling 事件并携带提取的路径
          ToolCallProgress(
            toolName: 'write_file',
            partialArguments: '{"path": "/notes/a.md", "content": "第一段',
          ),
          // 工具与关键信息均未变化：应被去重
          ToolCallProgress(
            toolName: 'write_file',
            partialArguments: '{"path": "/notes/a.md", "content": "第一段第二段',
          ),
          // 换了另一个工具：应再次产出事件
          ToolCallProgress(toolName: 'read_file', partialArguments: '{"path": "/notes/b.md"}'),
        ],
      );
      final loop = AgentLoop(aiService: mockAi, dispatcher: ToolDispatcher());

      final callingEvents = <AgentEvent>[];
      await for (final event in loop.run(
        conversationHistory: [],
        systemPrompt: '系统提示词',
      )) {
        if (event.type == AgentEventType.toolCalling) {
          callingEvents.add(event);
        }
      }

      expect(callingEvents.length, 2);
      expect(callingEvents[0].toolCall!.name, 'write_file');
      expect(callingEvents[0].toolCall!.arguments['path'], '/notes/a.md');
      expect(callingEvents[1].toolCall!.name, 'read_file');
      expect(callingEvents[1].toolCall!.arguments['path'], '/notes/b.md');
    });
  });
}
