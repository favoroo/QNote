import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
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

  MockAiService({
    this.textDeltas = const ['测试回答'],
    this.returnToolCalls = const [],
  });

  @override
  Stream<String> chatStreamWithTools({
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
  }) async* {
    for (final delta in textDeltas) {
      yield delta;
    }
    if (returnToolCalls.isNotEmpty) {
      onToolCallsReady?.call(returnToolCalls);
    }
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
  });
}
