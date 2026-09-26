import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/tts/streaming_speech_session.dart';

/// 记录调用顺序的假朗读通道：本类的价值就在于不碰 Riverpod、音频与网络
class _FakeSink implements SpeechSink {
  final List<String> events = [];

  @override
  void beginSpeech(String messageId, {required String voice, required double rate}) {
    events.add('begin($messageId,$voice,$rate)');
  }

  @override
  void enqueueSpeech(String text) => events.add('enqueue($text)');

  @override
  void finishSpeech() => events.add('finish');

  @override
  Future<void> stop() async => events.add('stop');

  @override
  void retagMessage(String oldKey, String newKey) => events.add('retag($oldKey->$newKey)');
}

const _on = QVoiceSettings(autoRead: true, voice: 'zh-CN-XiaoxiaoNeural', rate: 1.0);
const _off = QVoiceSettings(autoRead: false, voice: 'v', rate: 1.0);

/// 一句 n 字的可朗读文本（含句末标点）
String s(int n) => '中' * n + '。';

void main() {
  late _FakeSink sink;

  setUp(() => sink = _FakeSink());

  StreamingSpeechSession start({
    QVoiceSettings settings = _on,
    Duration delay = Duration.zero,
    String keyPrefix = 'stream',
  }) {
    final session = StreamingSpeechSession(
      sink: sink,
      settings: Future<QVoiceSettings>.delayed(delay, () => settings),
      keyPrefix: keyPrefix,
    );
    return session;
  }

  group('开关与配置时序', () {
    test('自动朗读关闭时全程不触碰朗读通道', () async {
      final session = start(settings: _off);
      session.onContentDelta(s(60));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      session
        ..onContentDelta(s(60))
        ..onFinish('msg_assistant_final');

      expect(sink.events, isEmpty);
      expect(session.hasStartedSpeaking, isFalse);
    });

    test('配置未到位时先把段扣住，到位后一次性放行', () async {
      final session = start(delay: const Duration(milliseconds: 20));
      // 首段在配置读回来之前就切好了
      session.onContentDelta(s(45));
      expect(sink.events, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      session.onContentDelta(s(45));
      expect(sink.events.first, startsWith('begin(stream#0'));
      expect(sink.events.where((e) => e.startsWith('enqueue')), hasLength(2));
    });

    test('配置迟迟读不到就放弃本场，不留迟到语音炸弹', () async {
      final session = start(delay: const Duration(minutes: 1));
      for (var i = 0; i < 30; i++) {
        session.onContentDelta(s(45));
      }
      expect(sink.events, isEmpty);
      expect(session.hasStartedSpeaking, isFalse);
    });
  });

  group('分段开口', () {
    test('未过门槛的短回复在收尾时才第一次开口', () async {
      final session = start();
      session.onContentDelta('好呀');
      await Future<void>.delayed(Duration.zero);
      session
        ..onContentDelta('，很高兴见到你。')
        ..onFinish('msg_assistant_final');

      expect(sink.events, containsAllInOrder([
        startsWith('begin(stream#0'),
        startsWith('enqueue('),
        'retag(stream#0->msg_assistant_final)',
        'finish',
      ]));
    });

    test('长回复在流式期间就逐段开口，不等收尾', () async {
      final session = start();
      await Future<void>.delayed(Duration.zero);
      session.onContentDelta(s(45));
      expect(sink.events, hasLength(2)); // begin + 第一段
      session.onContentDelta(s(120));
      expect(sink.events, hasLength(3)); // 第二段当场跟上
    });
  });

  group('轮次与中止', () {
    test('还没开口时新一轮不打断朗读通道', () async {
      final session = start();
      await Future<void>.delayed(Duration.zero);
      session.onContentDelta('零星几个字');
      session.onTurnStart();

      expect(sink.events, isEmpty);
    });

    test('已经开口后新一轮会掐掉上一轮并重新起算', () async {
      final session = start();
      await Future<void>.delayed(Duration.zero);
      session.onContentDelta(s(45));
      expect(session.hasStartedSpeaking, isTrue);

      session.onTurnStart();
      expect(sink.events, contains('stop'));

      sink.events.clear();
      session.onContentDelta(s(45));
      // 新轮用新的临时 key，避免与上一轮的 retag 撞车
      expect(sink.events.first, startsWith('begin(stream#1'));
    });

    test('中止后剩余正文不再出声', () async {
      final session = start();
      await Future<void>.delayed(Duration.zero);
      session.onContentDelta(s(45));
      session.onAbort();
      expect(sink.events, contains('stop'));

      sink.events.clear();
      session
        ..onContentDelta(s(120))
        ..onFinish('msg_assistant_final');
      // 中止是终态：本场不会再重新开口
      expect(sink.events, isEmpty);
    });
  });

  group('总量护栏', () {
    test('超过朗读总量上限就收尾提示，不把长回复全念完', () async {
      final session = start();
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 40; i++) {
        session.onContentDelta(s(50));
      }
      session.onFinish('msg_assistant_final');

      final spoken = sink.events.where((e) => e.startsWith('enqueue')).length;
      expect(sink.events.last, 'finish');
      // 护栏之上还补了一句「后文略」
      expect(sink.events.any((e) => e.contains('后文略')), isTrue);
      expect(spoken, lessThan(40));
    });
  });
}
