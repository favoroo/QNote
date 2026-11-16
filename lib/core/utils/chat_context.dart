import 'package:qnote_flutter/models/chat_session.dart';

/// 构建发送给模型的历史上下文。
///
/// 与界面展示用的消息列表不同：
/// - 失败提示（`isError` 的 assistant 消息）只属于界面，不能当成小Q的回复回灌给模型；
/// - 工具执行中途失败会在历史尾部留下「assistant(tool_calls) 没有完整 tool 结果」的
///   残链，OpenAI 兼容接口会因 tool_call_id 失配直接返回 400，因此尾部残缺组整体剔除
///   （界面仍保留这些步骤，供用户回看工作过程）。
///
/// 界面派生的 `workflow` / `thought` 伪消息不落库，这里再兜底过滤一次。
List<ChatMessage> buildModelConversationHistory(List<ChatMessage> messages) {
  final history = messages.where((m) => m.isError != true && m.role != 'workflow' && m.role != 'thought').toList();
  return _trimIncompleteToolTail(history);
}

/// 剔除尾部不完整的工具调用组；历史完整时原样返回。
List<ChatMessage> _trimIncompleteToolTail(List<ChatMessage> history) {
  // 只需检查最后一条 assistant：更早的工具轮后面还有消息，说明已经完整收尾
  for (var i = history.length - 1; i >= 0; i--) {
    final msg = history[i];
    if (msg.role != 'assistant') continue;
    final calls = msg.toolCalls;
    if (calls == null || calls.isEmpty) return history;

    final resultIds = <String>{};
    for (var j = i + 1; j < history.length; j++) {
      final next = history[j];
      if (next.role != 'tool') break;
      final id = next.toolCallId;
      if (id != null) resultIds.add(id);
    }
    final complete = calls.every((call) => resultIds.contains(call.id));
    return complete ? history : history.sublist(0, i);
  }
  return history;
}
