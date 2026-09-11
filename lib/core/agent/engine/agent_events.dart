import 'package:qnote_flutter/models/chat_session.dart';

/// Agent 事件类型
enum AgentEventType {
  turnStart,
  thoughtUpdate,
  contentDelta, // 文本流打字机碎片
  toolExecuting,
  toolCompleted,
  assistantMessage,
  finished,
  error,
}

/// Agent 事件，用于向 UI 实时推流
class AgentEvent {
  final AgentEventType type;
  final int? turn;
  final String? text;
  final ToolCall? toolCall;
  final ChatMessage? message;
  final String? error;

  const AgentEvent({
    required this.type,
    this.turn,
    this.text,
    this.toolCall,
    this.message,
    this.error,
  });

  factory AgentEvent.turnStart(int turn) =>
      AgentEvent(type: AgentEventType.turnStart, turn: turn);

  factory AgentEvent.thoughtUpdate(String thought) =>
      AgentEvent(type: AgentEventType.thoughtUpdate, text: thought);

  factory AgentEvent.contentDelta(String deltaText) =>
      AgentEvent(type: AgentEventType.contentDelta, text: deltaText);

  factory AgentEvent.toolExecuting(ToolCall toolCall, {String? progress}) =>
      AgentEvent(
        type: AgentEventType.toolExecuting,
        toolCall: toolCall,
        text: progress,
      );

  factory AgentEvent.toolCompleted(ToolCall toolCall, ChatMessage result) =>
      AgentEvent(
        type: AgentEventType.toolCompleted,
        toolCall: toolCall,
        message: result,
      );

  factory AgentEvent.assistantMessage(ChatMessage message) =>
      AgentEvent(type: AgentEventType.assistantMessage, message: message);

  factory AgentEvent.finished(ChatMessage finalMessage) =>
      AgentEvent(type: AgentEventType.finished, message: finalMessage);

  factory AgentEvent.error(String error) =>
      AgentEvent(type: AgentEventType.error, error: error);
}
