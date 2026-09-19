import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  group('TtsPlayer.messageKeyOf', () {
    test('内容相同的不同对象产生相同 key（自动朗读与气泡渲染对齐）', () {
      final a = ChatMessage(
        role: 'assistant',
        content: '最终答复内容',
        timestamp: DateTime(2026, 9, 19, 12, 0, 0),
      );
      // AgentLoop 的 assistantMessage 与 finished 事件各构造一次时，
      // 时间戳会有毫秒级差异，key 仍必须一致
      final b = ChatMessage(
        role: 'assistant',
        content: '最终答复内容',
        timestamp: DateTime(2026, 9, 19, 12, 0, 0, 123),
      );
      expect(TtsPlayer.messageKeyOf(a), TtsPlayer.messageKeyOf(b));
    });

    test('不同内容产生不同 key', () {
      final a = ChatMessage(role: 'assistant', content: '回复一');
      final b = ChatMessage(role: 'assistant', content: '回复二');
      expect(
        TtsPlayer.messageKeyOf(a),
        isNot(TtsPlayer.messageKeyOf(b)),
      );
    });

    test('相同内容不同角色产生不同 key', () {
      final a = ChatMessage(role: 'user', content: '同样的话');
      final b = ChatMessage(role: 'assistant', content: '同样的话');
      expect(
        TtsPlayer.messageKeyOf(a),
        isNot(TtsPlayer.messageKeyOf(b)),
      );
    });
  });
}
