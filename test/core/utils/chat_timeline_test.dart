import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 会话时间线归一化：多轮思考的可见性、顺序与工具链聚合
void main() {
  ChatMessage assistant({
    String content = '',
    String? thought,
    int? thoughtSeconds,
    List<ToolCall>? toolCalls,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      role: 'assistant',
      content: content,
      thought: thought,
      thoughtSeconds: thoughtSeconds,
      toolCalls: toolCalls,
      timestamp: timestamp,
    );
  }

  ChatMessage tool(String name, {DateTime? timestamp}) {
    return ChatMessage(role: 'tool', content: '结果', toolName: name, timestamp: timestamp);
  }

  test('中间轮的思考不会随中转消息一起被丢弃', () {
    // 典型 ReAct 两轮：思考1 → 工具 → 思考2+正文
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '查一下'),
      assistant(
        thought: '先看目录',
        thoughtSeconds: 2,
        toolCalls: const [ToolCall(id: '1', name: 'list_dir', arguments: {})],
      ),
      tool('list_dir'),
      assistant(content: '查完了', thought: '整理结果', thoughtSeconds: 3),
    ]);

    expect(entries.map((e) => e.message.role), ['user', 'thought', 'tool', 'thought', 'assistant']);
    expect(entries[1].message.content, '先看目录');
    expect(entries[1].message.thoughtSeconds, 2);
    expect(entries[3].message.content, '整理结果');
    expect(entries[3].message.thoughtSeconds, 3);
  });

  test('正文气泡不再重复携带 thought', () {
    final entries = buildChatTimelineEntries([assistant(content: '答案', thought: '推理')]);

    expect(entries, hasLength(2));
    expect(entries[0].message.role, 'thought');
    expect(entries[1].message.role, 'assistant');
    expect(entries[1].message.thought, isEmpty);
    expect(entries[1].stateIndex, 0);
  });

  test('连续工具结果聚合为 tool_group，单个工具保持原样', () {
    final grouped = buildChatTimelineEntries([tool('read_file'), tool('read_file'), tool('grep')]);
    expect(grouped, hasLength(1));
    expect(grouped.first.message.role, 'tool_group');
    expect((grouped.first.message.uiDetails?['messages'] as List).length, 3);

    final single = buildChatTimelineEntries([tool('read_file')]);
    expect(single, hasLength(1));
    expect(single.first.message.role, 'tool');
  });

  test('思考步骤会打断工具链，保持原始发生顺序', () {
    final entries = buildChatTimelineEntries([tool('read_file'), assistant(thought: '再想想'), tool('read_file')]);

    expect(entries.map((e) => e.message.role), ['tool', 'thought', 'tool']);
  });

  test('ask_user 与 generate_image 不进入折叠链', () {
    final entries = buildChatTimelineEntries([
      tool('ask_user'),
      tool('ask_user'),
      tool('generate_image'),
      tool('generate_image'),
    ]);

    expect(entries.every((e) => e.message.role == 'tool'), isTrue, reason: '交互卡片与大图卡片被折叠后会完全看不到');
  });

  test('纯中转消息（无正文、无思考）完全不展示', () {
    final entries = buildChatTimelineEntries([
      assistant(
        toolCalls: const [ToolCall(id: '1', name: 'grep', arguments: {})],
      ),
    ]);

    expect(entries, isEmpty);
  });

  test('stateIndex 指向原始行，思考与聚合卡为 null', () {
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: 'hi'),
      assistant(content: '你好', thought: '想一下'),
    ]);

    expect(entries[0].stateIndex, 0);
    expect(entries[1].stateIndex, isNull);
    expect(entries[2].stateIndex, 1);
  });
}
