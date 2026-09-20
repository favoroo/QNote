import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  group('TtsPlayer.playbackFinished', () {
    test('播完时 playing 仍为 true 也必须判定为结束', () {
      // just_audio 的 playing 只在 pause/stop 时回落，自然播完是
      // PlayerState(playing: true, completed)；若额外要求 !playing，
      // 朗读状态永远停在 playing，气泡按钮会卡在停止图标（需点两下才恢复）
      expect(
        TtsPlayer.playbackFinished(
          PlayerState(true, ProcessingState.completed),
        ),
        isTrue,
      );
    });

    test('暂停后的 completed 同样判定为结束', () {
      expect(
        TtsPlayer.playbackFinished(
          PlayerState(false, ProcessingState.completed),
        ),
        isTrue,
      );
    });

    test('加载/就绪/空闲等中间态不算结束', () {
      for (final state in const [
        ProcessingState.idle,
        ProcessingState.loading,
        ProcessingState.buffering,
        ProcessingState.ready,
      ]) {
        expect(
          TtsPlayer.playbackFinished(PlayerState(true, state)),
          isFalse,
          reason: 'processingState=$state 仍在朗读中',
        );
      }
    });
  });

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
