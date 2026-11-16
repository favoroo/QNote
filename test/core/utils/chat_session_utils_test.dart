import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/utils/chat_session_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';

/// 历史欢迎语清理与会话空态判定
void main() {
  final greeting = defaultSystemPrompts['assistant_greeting']!;
  final now = DateTime(2026, 1, 1, 9, 30);

  ChatMessage message(String role, String content, {Map<String, dynamic>? uiDetails}) =>
      ChatMessage(role: role, content: content, uiDetails: uiDetails);

  ChatSession sessionWith(List<ChatMessage> messages, {String title = '新对话'}) =>
      ChatSession(id: 'session-1', title: title, messages: messages, createdAt: now, updatedAt: now);

  group('stripLegacyGreeting', () {
    test('剔除开头的欢迎语并保留后续真实对话', () {
      final messages = [message('assistant', greeting), message('user', '记一下明天要交房租'), message('assistant', '记好了')];

      final stripped = stripLegacyGreeting(messages);

      expect(stripped.map((m) => m.content), ['记一下明天要交房租', '记好了']);
    });

    test('没有欢迎语时原样返回同一个列表，保证派生缓存引用不失效', () {
      final messages = [message('user', '你好')];

      expect(identical(stripLegacyGreeting(messages), messages), isTrue);
    });

    test('只剔除首条：用户正文与回复里出现相同文本不受影响', () {
      final messages = [message('user', greeting), message('assistant', greeting)];

      expect(stripLegacyGreeting(messages), hasLength(2));
    });

    test('带 uiDetails 的消息即使正文相同也不被当成欢迎语', () {
      final messages = [
        message('assistant', greeting, uiDetails: {'type': 'turn_limit'}),
      ];

      expect(stripLegacyGreeting(messages), hasLength(1));
    });
  });

  group('stripLegacyGreetingSession', () {
    test('无欢迎语时返回原会话实例', () {
      final session = sessionWith([message('user', '你好')]);

      expect(identical(stripLegacyGreetingSession(session), session), isTrue);
    });

    test('有欢迎语时剔除并保留标题、时间等元数据', () {
      final session = sessionWith([message('assistant', greeting), message('user', '你好')], title: '今天记录');

      final stripped = stripLegacyGreetingSession(session);

      expect(stripped.messages.map((m) => m.content), ['你好']);
      expect(stripped.title, '今天记录');
      expect(stripped.createdAt, now);
      expect(stripped.updatedAt, now);
    });
  });

  group('isBlankNewChatSession', () {
    test('没有消息的新对话是空白会话', () {
      expect(isBlankNewChatSession(sessionWith(const [])), isTrue);
    });

    test('只有历史欢迎语的新对话仍视为空白，新建时可直接复用', () {
      expect(isBlankNewChatSession(sessionWith([message('assistant', greeting)])), isTrue);
    });

    test('已有真实提问的新对话不再空白', () {
      expect(isBlankNewChatSession(sessionWith([message('assistant', greeting), message('user', '记一下')])), isFalse);
    });

    test('已改过标题的会话不再空白，即便消息列表为空', () {
      expect(isBlankNewChatSession(sessionWith(const [], title: '旧对话')), isFalse);
    });

    test('null 会话不是空白会话', () {
      expect(isBlankNewChatSession(null), isFalse);
    });
  });
}
