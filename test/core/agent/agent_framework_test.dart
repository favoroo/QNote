import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  group('小Q Agent 核心框架测试', () {
    test('ToolDispatcher 注册与 Definitions 导出完整性', () {
      final dispatcher = AgentToolRegistry.createDefaultDispatcher();
      final defs = dispatcher.toFunctionDefinitions();

      expect(defs.isNotEmpty, true);
      final names = defs.map((d) => (d['function'] as Map)['name']).toSet();

      expect(names.contains('grep'), true);
      expect(names.contains('edit'), true);
      expect(names.contains('ask_user'), true);
      expect(names.contains('manage_todo'), true);
      expect(names.contains('manage_timeline'), true);
      expect(names.contains('manage_journal'), true);
      expect(names.contains('manage_note'), true);
      expect(names.contains('manage_settings'), true);
    });

    test('ToolDispatcher dispatch 未知工具能安全返回 isError 消息', () async {
      final dispatcher = AgentToolRegistry.createDefaultDispatcher();
      final call = ToolCall(
        id: 'test_call_1',
        name: 'non_existent_tool',
        arguments: {},
      );

      final result = await dispatcher.dispatch(call);
      expect(result.role, 'tool');
      expect(result.isError, true);
      expect(result.content.contains('找不到工具'), true);
      expect(result.toolCallId, 'test_call_1');
    });

    test('ToolCall 与 ChatMessage 模型序列化与反序列化完整性', () {
      final toolCall = ToolCall(
        id: 'call_123',
        name: 'manage_todo',
        arguments: {'action': 'create', 'title': '测试待办'},
      );

      final msg = ChatMessage(
        role: 'assistant',
        content: '我为你创建了一条待办',
        thought: '用户想记录一件事情',
        toolCalls: [toolCall],
      );

      final map = msg.toMap();
      final restored = ChatMessage.fromMap(map);

      expect(restored.role, 'assistant');
      expect(restored.thought, '用户想记录一件事情');
      expect(restored.toolCalls?.length, 1);
      expect(restored.toolCalls?.first.name, 'manage_todo');
      expect(restored.toolCalls?.first.arguments['title'], '测试待办');
    });
  });
}
