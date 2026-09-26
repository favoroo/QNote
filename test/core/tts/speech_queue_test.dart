import 'dart:async';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/speech_queue.dart';

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  group('播放顺序', () {
    test('按入队顺序合成与播放，一段不落', () async {
      final played = <SpeechSegment>[];
      final queue = SpeechQueue(
        synthesize: (text) async => _bytes(text),
        play: (segment) async => played.add(segment),
      );
      unawaited(queue.run());
      queue
        ..add('第一段')
        ..add('第二段')
        ..add('第三段');
      queue.close();
      await queue.run();

      expect(played.map((s) => s.text), ['第一段', '第二段', '第三段']);
      expect(played.map((s) => s.index), [0, 1, 2]);
      expect(played.every((s) => s.hasAudio), isTrue);
    });

    test('未收尾时等待更多片段，收尾后才结束', () async {
      final queue = SpeechQueue(
        synthesize: (text) async => _bytes(text),
        play: (segment) async {},
      );
      var done = false;
      final running = queue.run().whenComplete(() => done = true);
      queue.add('还在生成中');
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      queue.close();
      await running;
      expect(done, isTrue);
    });

    test('一段都没入队就收尾，直接结束不报错', () async {
      final queue = SpeechQueue(
        synthesize: (text) async => _bytes(text),
        play: (segment) async => fail('不该播放'),
      )..close();
      await queue.run();
    });
  });

  group('预取', () {
    test('合成最多领先播放位置 prefetch 段', () async {
      var inFlight = 0;
      var peak = 0;
      final started = <String>[];
      final queue = SpeechQueue(
        prefetch: 2,
        synthesize: (text) async {
          inFlight++;
          peak = max(peak, inFlight);
          started.add(text);
          // 每段合成都要让出事件循环，才逼得出并发上限
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return _bytes(text);
        },
        play: (segment) async {},
      );

      unawaited(queue.run());
      queue
        ..add('甲')
        ..add('乙')
        ..add('丙')
        ..add('丁');
      queue.close();
      await queue.run();

      expect(started, ['甲', '乙', '丙', '丁']);
      expect(peak, 2);
    });
  });

  group('失败与作废', () {
    test('合成失败带着 error 交给播放回调，队列继续', () async {
      final played = <SpeechSegment>[];
      final queue = SpeechQueue(
        synthesize: (text) async =>
            text == '坏' ? throw StateError('合成炸了') : _bytes(text),
        play: (segment) async => played.add(segment),
      );
      unawaited(queue.run());
      queue
        ..add('坏')
        ..add('好');
      queue.close();
      await queue.run();

      expect(played.first.error, isA<StateError>());
      expect(played.first.hasAudio, isFalse);
      expect(played.last.hasAudio, isTrue);
    });

    test('系统语音模式（合成返回 null）不算失败', () async {
      final played = <SpeechSegment>[];
      final queue = SpeechQueue(
        synthesize: (text) async => null,
        play: (segment) async => played.add(segment),
      );
      unawaited(queue.run());
      queue
        ..add('甲')
        ..add('乙');
      queue.close();
      await queue.run();

      expect(played, hasLength(2));
      expect(played.every((s) => s.error == null && !s.hasAudio), isTrue);
    });

    test('播放回调抛错即终止并把原因交给 run 的调用方', () async {
      var plays = 0;
      final queue = SpeechQueue(
        synthesize: (text) async => _bytes(text),
        play: (segment) async {
          plays++;
          throw StateError('播放器炸了');
        },
      );
      unawaited(queue.run());
      queue.add('甲');
      queue.add('乙');
      queue.close();

      await expectLater(queue.run(), throwsA(isA<StateError>()));
      expect(plays, 1);
    });

    test('作废后剩余片段不再播放', () async {
      var cancelled = false;
      final played = <String>[];
      final queue = SpeechQueue(
        synthesize: (text) async => _bytes(text),
        play: (segment) async {
          played.add(segment.text);
          // 首段念完时用户按了停止：本场就此收住
          if (segment.index == 0) cancelled = true;
        },
        isCancelled: () => cancelled,
      );
      unawaited(queue.run());
      queue
        ..add('甲')
        ..add('乙');
      queue.close();
      await queue.run();

      expect(played, ['甲']);
    });
  });
}
