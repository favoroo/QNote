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

      // VFS 通用原语工具集（对齐 pi-agent 精简理念）
      expect(names.contains('list_dir'), true);
      expect(names.contains('read_file'), true);
      expect(names.contains('write_file'), true);
      expect(names.contains('edit_file'), true);
      expect(names.contains('delete_file'), true);
      expect(names.contains('skill'), true);
      expect(names.contains('grep'), true);
      expect(names.contains('ask_user'), true);

      // 已移除的冗余业务工具不应再注册
      expect(names.contains('manage_todo'), false);
      expect(names.contains('manage_note'), false);
      expect(names.contains('edit'), false);
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
        name: 'write_file',
        arguments: {'path': '/todos/今日/测试待办.md', 'content': '测试内容'},
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
      expect(restored.toolCalls?.first.name, 'write_file');
      expect(restored.toolCalls?.first.arguments['path'], '/todos/今日/测试待办.md');
    });
  });
}
