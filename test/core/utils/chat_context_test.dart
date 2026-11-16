import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_context.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 模型上下文构建：失败提示不进上下文、中断残留的工具链不触发 400
void main() {
  ChatMessage toolResult(String id) {
    return ChatMessage(role: 'tool', content: '结果', toolCallId: id, toolName: 'read_file');
  }

  ChatMessage assistantCall(List<String> ids, {String content = ''}) {
    return ChatMessage(
      role: 'assistant',
      content: content,
      toolCalls: [for (final id in ids) ToolCall(id: id, name: 'read_file', arguments: const {})],
    );
  }

  test('失败提示（isError）不进入模型上下文，用户与正常回复保留', () {
    final history = buildModelConversationHistory([
      ChatMessage(role: 'user', content: '查一下'),
      ChatMessage(role: 'assistant', content: '本轮对话请求失败', isError: true),
      ChatMessage(role: 'user', content: '再试一次'),
      ChatMessage(role: 'assistant', content: '查完了'),
    ]);

    expect(history.map((m) => m.content), ['查一下', '再试一次', '查完了']);
  });

  test('界面派生的 workflow / thought 伪消息被兜底过滤', () {
    final history = buildModelConversationHistory([
      ChatMessage(role: 'user', content: '你好'),
      ChatMessage(role: 'thought', content: '打个招呼'),
      ChatMessage(role: 'workflow', content: ''),
      ChatMessage(role: 'assistant', content: '你好！'),
    ]);

    expect(history.map((m) => m.role), ['user', 'assistant']);
  });

  test('完整的工具调用链原样保留', () {
    final messages = [
      ChatMessage(role: 'user', content: '查一下'),
      assistantCall(['call_1']),
      toolResult('call_1'),
      ChatMessage(role: 'assistant', content: '查完了'),
    ];

    expect(buildModelConversationHistory(messages), messages);
  });

  test('尾部 assistant(tool_calls) 完全没有工具结果时剔除该残链', () {
    final history = buildModelConversationHistory([
      ChatMessage(role: 'user', content: '查一下'),
      assistantCall(['call_1'], content: '我先读文件'),
    ]);

    expect(history.map((m) => m.role), ['user']);
  });

  test('并行工具只回来部分结果时剔除整条残缺组（含已回的结果）', () {
    final history = buildModelConversationHistory([
      ChatMessage(role: 'user', content: '查一下'),
      assistantCall(['call_1', 'call_2']),
      toolResult('call_1'),
    ]);

    expect(history.map((m) => m.role), ['user']);
  });

  test('尾部是普通答复（无 toolCalls）时不受影响', () {
    final history = buildModelConversationHistory([
      ChatMessage(role: 'user', content: '你好'),
      ChatMessage(role: 'assistant', content: '你好！'),
    ]);

    expect(history, hasLength(2));
  });
}
