import 'package:qnote_flutter/models/chat_session.dart';

/// 会话时间线上的一个展示项
///
/// [stateIndex] 指向该项在原始 `session.messages` 中的下标（撤回/重试要用）；
/// 思考步骤与工具聚合卡属于派生项，没有原始行，保持 null。
class ChatTimelineEntry {
  final ChatMessage message;
  final int? stateIndex;

  const ChatTimelineEntry(this.message, [this.stateIndex]);
}

/// 单条消息是否需要作为独立气泡展示
///
/// Agent 在每轮发起工具调用前，都会生成一条「正文为空、仅承载 tool_calls」的
/// assistant 消息来维持协议完整。这类消息属于内部中转，不应单独成泡；
/// 它的思考段会在 [buildChatTimelineEntries] 里被抽成独立步骤。
bool isChatTimelineVisibleMessage(ChatMessage message) {
  if (message.role == 'user') return true;
  if (message.content.trim().isNotEmpty) return true;
  if (message.role == 'tool') return true;
  if (message.uiDetails != null) return true;
  return false;
}

/// 工具结果是否可并入「执行步骤」折叠链
///
/// `ask_user` 需保持独立交互卡片；`generate_image` 需保持独立大图卡片——
/// 若被折叠隐藏，正文里的同图又已按「卡片已展示」去重，用户将一张图都看不到。
bool isGroupableToolMessage(ChatMessage message) {
  return message.toolName != 'ask_user' && message.toolName != 'generate_image';
}

/// 把会话消息归一成时间线展示项。
///
/// 两步：
/// 1. 每条 assistant 消息的 thought 抽成独立的 `role: 'thought'` 步骤项，
///    多轮 ReAct 里每段思考因此都能被单独折叠/展开（此前中间轮的思考会随
///    「仅承载 tool_calls」的消息一起被过滤掉，只剩最后一轮可见）；
/// 2. 连续 ≥2 条工具结果聚合成 `role: 'tool_group'` 折叠链；思考步骤会打断
///    工具链，保证「思考 → 工具 → 思考」的原始顺序。
List<ChatTimelineEntry> buildChatTimelineEntries(List<ChatMessage> messages) {
  final expanded = <ChatTimelineEntry>[];
  for (var i = 0; i < messages.length; i++) {
    final msg = messages[i];
    final thought = msg.role == 'assistant' ? (msg.thought?.trim() ?? '') : '';
    if (thought.isNotEmpty) {
      expanded.add(
        ChatTimelineEntry(
          ChatMessage(role: 'thought', content: thought, thoughtSeconds: msg.thoughtSeconds, timestamp: msg.timestamp),
        ),
      );
    }
    if (!isChatTimelineVisibleMessage(msg)) {
      continue;
    }
    // 思考已经单独入列，气泡本体不再重复渲染
    expanded.add(ChatTimelineEntry(thought.isEmpty ? msg : msg.copyWith(thought: ''), i));
  }

  final entries = <ChatTimelineEntry>[];
  var i = 0;
  while (i < expanded.length) {
    final entry = expanded[i];
    final msg = entry.message;

    if (msg.role == 'tool' && isGroupableToolMessage(msg)) {
      final toolGroup = <ChatMessage>[msg];
      var j = i + 1;
      while (j < expanded.length) {
        final next = expanded[j].message;
        if (next.role == 'tool' && isGroupableToolMessage(next)) {
          toolGroup.add(next);
          j++;
        } else {
          break;
        }
      }
      if (toolGroup.length >= 2) {
        entries.add(
          ChatTimelineEntry(
            ChatMessage(
              role: 'tool_group',
              content: '',
              timestamp: toolGroup.first.timestamp,
              uiDetails: {'messages': toolGroup},
            ),
          ),
        );
        i = j;
        continue;
      }
    }

    entries.add(entry);
    i++;
  }

  return entries;
}
