import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('TtsPlayer.retagMessage', () {
    test('流式临时 key 换成正式 key 后状态不变，气泡按钮才对得上', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final player = container.read(ttsPlaybackProvider.notifier);

      player.beginSpeech(
        'stream#0',
        voice: 'zh-CN-XiaoxiaoNeural',
        rate: 1.0,
      );
      expect(
        container.read(ttsPlaybackProvider).status,
        TtsPlaybackStatus.synthesizing,
      );

      player.retagMessage('stream#0', 'msg_assistant_final');
      final retagged = container.read(ttsPlaybackProvider);
      expect(retagged.messageId, 'msg_assistant_final');
      // 状态必须原样保留：换 key 期间朗读没停，按钮不该闪回"朗读"态
      expect(retagged.status, TtsPlaybackStatus.synthesizing);
    });

    test('旧 key 已被新任务取代时换名不生效', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final player = container.read(ttsPlaybackProvider.notifier);

      player.beginSpeech('stream#0', voice: 'v', rate: 1.0);
      player.retagMessage('stream#0', 'msg_assistant_first');
      // 上一轮的迟到收尾不能把这一轮的朗读改错名字
      player.retagMessage('stream#0', 'msg_assistant_stale');
      expect(
        container.read(ttsPlaybackProvider).messageId,
        'msg_assistant_first',
      );
    });
  });

  group('TtsPlayer 分段朗读链路', () {
    // flutter_tts 平台通道的调用记录：speak 的文本序列与 stop 次数。
    // 走系统语音路径（不实例化 just_audio），即可在单测里驱动真实的
    // begin→enqueue→finish 编排，覆盖串行链与播放循环的衔接
    final spokenTexts = <String>[];
    var stopCount = 0;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
            call,
          ) async {
            if (call.method == 'speak') {
              // Android 端 speak 传 Map，其余平台直接传文本字符串
              final arg = call.arguments;
              spokenTexts.add(arg is Map ? arg['text'] as String : arg as String);
            } else if (call.method == 'stop') {
              stopCount++;
            }
            return 1;
          });
    });

    /// 轮询等待状态迁移；死锁回归时条件永假，靠超时把测试打红
    Future<void> waitUntil(
      bool Function() condition, {
      required String timeoutMessage,
    }) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail(timeoutMessage);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('begin→enqueue→finish 后各段按序播出并正常收尾', () async {
      SharedPreferences.setMockInitialValues({});
      spokenTexts.clear();
      stopCount = 0;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final player = container.read(ttsPlaybackProvider.notifier);

      player.beginSpeech(
        'stream#0',
        voice: QVoiceConfig.systemVoiceId,
        rate: 1.0,
      );
      player.enqueueSpeech('第一段。');
      player.enqueueSpeech('第二段。');
      player.enqueueSpeech('第三段。');
      player.finishSpeech();

      // 回归点：清场与播放循环曾被串行链互相堵死，状态永远卡在
      // synthesizing、整场无声；此处等不到 idle 即超时失败
      await waitUntil(
        () =>
            container.read(ttsPlaybackProvider).status == TtsPlaybackStatus.idle,
        timeoutMessage: '分段朗读链路死锁：finishSpeech 后状态未回到 idle',
      );
      expect(spokenTexts, ['第一段。', '第二段。', '第三段。']);
      // 首段 resetQueue 掐一次残留朗读，段间靠 awaitSpeakCompletion 串行，不再 stop
      expect(stopCount, 1);
    });

    test('begin 后立即 stop：不播出任何段并复位为空闲', () async {
      SharedPreferences.setMockInitialValues({});
      spokenTexts.clear();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final player = container.read(ttsPlaybackProvider.notifier);

      player.beginSpeech(
        'stream#1',
        voice: QVoiceConfig.systemVoiceId,
        rate: 1.0,
      );
      player.enqueueSpeech('不该被念出来。');
      await player.stop();

      final state = container.read(ttsPlaybackProvider);
      expect(state.status, TtsPlaybackStatus.idle);
      expect(state.error, isNull);
      expect(state.messageId, isNull);
      // 留出事件循环窗口，确认清场后没有任何 speak 发生
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(spokenTexts, isEmpty);
    });
  });
}
