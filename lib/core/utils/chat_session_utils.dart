import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 是否为旧版本新建会话时预置的小Q欢迎语。
///
/// 欢迎语不是真实对话内容：它既不该在会话流里占一个气泡，也不该进入模型上下文。
/// 新版本已不再写入，这里统一兜底清理历史会话。
bool isLegacyGreetingMessage(ChatMessage message) {
  final greeting = defaultSystemPrompts['assistant_greeting'];
  return greeting != null &&
      greeting.isNotEmpty &&
      message.role == 'assistant' &&
      message.content == greeting &&
      message.uiDetails == null;
}

/// 去掉历史会话开头的小Q欢迎语。
///
/// 没有欢迎语时原样返回入参，保持列表引用不变（页面用 `identical` 命中派生缓存）；
/// 确实需要剔除时返回去掉首条后的新列表。
List<ChatMessage> stripLegacyGreeting(List<ChatMessage> messages) {
  if (messages.isEmpty || !isLegacyGreetingMessage(messages.first)) {
    return messages;
  }
  return messages.sublist(1);
}

/// 去掉会话开头的小Q欢迎语；无需剔除时返回原实例，避免无谓的重建。
ChatSession stripLegacyGreetingSession(ChatSession session) {
  final messages = stripLegacyGreeting(session.messages);
  return identical(messages, session.messages) ? session : session.copyWith(messages: messages);
}
