import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 会话时间线归一化：工作流归并、特殊卡片外露、单思考直通与流式活跃轮次标记
void main() {
  ChatMessage assistant({
    String content = '',
    String? thought,
    int? thoughtSeconds,
    List<ToolCall>? toolCalls,
    bool? isError,
    Map<String, dynamic>? uiDetails,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      role: 'assistant',
      content: content,
      thought: thought,
      thoughtSeconds: thoughtSeconds,
      toolCalls: toolCalls,
      isError: isError,
      uiDetails: uiDetails,
      timestamp: timestamp,
    );
  }

  ChatMessage tool(String name, {bool isError = false, DateTime? timestamp}) {
    return ChatMessage(
      role: 'tool',
      content: isError ? '失败' : '结果',
      toolName: name,
      isError: isError,
      timestamp: timestamp,
    );
  }

  test('多轮 ReAct（思考 + 工具 + 中间过渡文案 + 最终输出）归并为一条工作流与最终输出', () {
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '查一下笔记'),
      assistant(
        thought: '先看目录',
        thoughtSeconds: 2,
        content: '我先查看一下笔记目录',
        toolCalls: const [ToolCall(id: '1', name: 'list_dir', arguments: {})],
      ),
      tool('list_dir'),
      assistant(
        thought: '再读文件',
        thoughtSeconds: 4,
        toolCalls: const [ToolCall(id: '2', name: 'read_file', arguments: {})],
      ),
      tool('read_file'),
      assistant(content: '查完了，共找到 2 条笔记', thought: '整理结论', thoughtSeconds: 3),
    ]);

    expect(entries.map((e) => e.message.role), ['user', 'workflow', 'assistant']);
    expect(entries[0].stateIndex, 0);
    expect(entries[1].stateIndex, isNull);
    expect(entries[2].stateIndex, 5);
    expect(entries[2].message.content, '查完了，共找到 2 条笔记');
    expect(entries[2].message.thought, isEmpty);

    final workflow = entries[1].message.uiDetails?['workflow'] as WorkflowData;
    expect(workflow.isLive, isFalse);
    expect(workflow.steps.map((s) => s.kind), [
      WorkflowStepKind.thought,
      WorkflowStepKind.prose,
      WorkflowStepKind.tool,
      WorkflowStepKind.thought,
      WorkflowStepKind.tool,
      WorkflowStepKind.thought,
    ]);
    expect(workflow.summary.totalThoughtSeconds, 9);
    expect(workflow.summary.readCount, 2);
    expect(workflow.summary.proseCount, 1);
    expect(workflow.summary.formatText(), '思考 9 秒 · 查阅 2 项');
  });

  test('仅有一段纯思考且无工具时直出 thought，避免二层嵌套折叠', () {
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '你好'),
      assistant(content: '你好！', thought: '打个招呼', thoughtSeconds: 3),
    ]);

    expect(entries.map((e) => e.message.role), ['user', 'thought', 'assistant']);
    expect(entries[1].message.content, '打个招呼');
    expect(entries[1].message.thoughtSeconds, 3);
    expect(entries[1].message.uiDetails?['turnKey'], 'turn_0_0');
    expect(entries[2].message.thought, isEmpty);
    expect(entries[2].stateIndex, 1);
  });

  test('流式活跃轮次（isLiveTurn: true）下即使是首段思考也先挂成 live workflow', () {
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '帮我修改'),
      assistant(
        thought: '先分析需求',
        thoughtSeconds: 2,
        toolCalls: const [ToolCall(id: '1', name: 'edit_file', arguments: {})],
      ),
    ], isLiveTurn: true);

    expect(entries.map((e) => e.message.role), ['user', 'workflow']);
    final workflow = entries[1].message.uiDetails?['workflow'] as WorkflowData;
    expect(workflow.isLive, isTrue);
    expect(workflow.turnKey, 'turn_0_0');
    expect(workflow.steps, hasLength(1));
  });

  test('ask_user 与 generate_image 保持外露，作为工作流边界分段', () {
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '画一张图'),
      tool('read_file'),
      tool('generate_image'),
      tool('write_file'),
      tool('ask_user'),
      assistant(content: '已完成'),
    ]);

    expect(entries.map((e) => e.message.role), ['user', 'workflow', 'tool', 'workflow', 'tool', 'assistant']);
    expect(entries[2].message.toolName, 'generate_image');
    expect(entries[4].message.toolName, 'ask_user');
    final w1 = entries[1].message.uiDetails?['workflow'] as WorkflowData;
    final w2 = entries[3].message.uiDetails?['workflow'] as WorkflowData;
    expect(w1.turnKey, 'turn_0_0');
    expect(w2.turnKey, 'turn_0_1');
  });

  test('turn_limit 与 isError 助手消息保持外露，不折入工作流', () {
    final entries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '继续'),
      tool('read_file'),
      assistant(content: '已达到步数上限', uiDetails: {'type': 'turn_limit', 'handled': false}),
    ]);

    expect(entries.map((e) => e.message.role), ['user', 'workflow', 'assistant']);
    expect(entries[2].message.uiDetails?['type'], 'turn_limit');

    final errorEntries = buildChatTimelineEntries([
      ChatMessage(role: 'user', content: '再试'),
      tool('read_file'),
      assistant(content: '请求失败', isError: true),
    ]);
    expect(errorEntries.map((e) => e.message.role), ['user', 'workflow', 'assistant']);
    expect(errorEntries[2].message.isError, isTrue);
  });

  test('纯中转消息（无正文、无思考）完全不展示', () {
    final entries = buildChatTimelineEntries([
      assistant(
        toolCalls: const [ToolCall(id: '1', name: 'grep', arguments: {})],
      ),
    ]);

    expect(entries, isEmpty);
  });

  test('工作流汇总文案覆盖查阅、修改、技能与异常计数', () {
    final summary = WorkflowSummary.fromSteps([
      WorkflowStep(
        kind: WorkflowStepKind.thought,
        message: ChatMessage(role: 'thought', content: 't1', thoughtSeconds: 5),
      ),
      WorkflowStep(kind: WorkflowStepKind.tool, message: tool('read_file')),
      WorkflowStep(kind: WorkflowStepKind.tool, message: tool('grep')),
      WorkflowStep(kind: WorkflowStepKind.tool, message: tool('edit_file', isError: true)),
      WorkflowStep(kind: WorkflowStepKind.tool, message: tool('skill')),
    ]);

    expect(summary.formatText(), '思考 5 秒 · 查阅 2 项，修改 1 项，调用技能 1 次 · 1 项异常');
  });
}
