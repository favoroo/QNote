import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/tts_service.dart';
import 'package:qnote_flutter/core/utils/speech_chunker.dart';

/// 生成一句 n 字可朗读文本（含句末标点，实际可朗读字数为 n+1）
String s(int n, {String end = '。', String unit = '中'}) => unit * n + end;

/// 去掉所有空白，用于字符守恒比对
String compact(String text) => text.replaceAll(RegExp(r'\s'), '');

void main() {
  late SpeechChunker chunker;

  setUp(() => chunker = SpeechChunker());

  group('首段门槛', () {
    test('不足门槛不出声，收尾时作为最后一段吐出', () {
      expect(chunker.feed('好。'), isEmpty);
      expect(chunker.flush(), ['好。']);
    });

    test('攒够门槛立即出声', () {
      expect(chunker.feed(s(45)), [s(45)]);
    });

    test('多个短句合并成一段，避免每句一次合成请求', () {
      expect(chunker.feed('一二三。'), isEmpty);
      expect(chunker.feed('四五六。'), isEmpty);
      final tail = s(35);
      expect(chunker.feed(tail), ['一二三。四五六。$tail']);
    });

    test('越过首段门槛后改用较宽松门槛，长句不再被合并成超大段', () {
      expect(chunker.feed(s(45)), hasLength(1));
      expect(chunker.feed('好。'), isEmpty);
      expect(chunker.feed(s(20)), ['好。${s(20)}']);
    });
  });

  group('切点选取', () {
    test('段长贴近目标段长，一句话也不会被拆成两段', () {
      // 连续句子优先凑到接近 maxChars 再切：段越少，Edge 每段一次握手越省
      final out = chunker.feed(List.generate(5, (_) => s(45)).join());
      expect(out, hasLength(2));
      expect(out.first, List.generate(3, (_) => s(45)).join());
      expect(out.last, List.generate(2, (_) => s(45)).join());
    });

    test('没有句号的英文与列表靠换行提供切点', () {
      const line = 'this line is long enough to speak aloud';
      final out = chunker.feed('$line\n$line\n');
      expect(out.single, '$line\n$line');
    });

    test('列表项合并进同一段，清洗后不残留列表符号', () {
      final out = chunker.feed('- ${s(45, unit: '甲')}\n- ${s(45, unit: '乙')}\n');
      expect(out, hasLength(1));
      expect(TtsService.cleanSpeechText(out.single, maxChars: null), isNot(contains('-')));
    });

    test('同一行内没有换行也能出段，不必等整段写完', () {
      // 长回复常整段不换气；若必须等换行才出声，首声优化就白做了
      expect(chunker.feed('${s(50)}后半句还在继续写'), [s(50)]);
    });

    test('等不到句末时在子句标点处硬切', () {
      final out = chunker.feed('${'无' * 250}，${'标' * 20}');
      expect(out.single.endsWith('，'), isTrue);
    });

    test('连子句标点都没有时按定长硬切，剩余留给下一段', () {
      final out = chunker.feed('字' * 300);
      expect(out.single, '字' * 160);
      expect(chunker.flush().single, '字' * 140);
    });

    test('比目标段长略长的整句不被打断', () {
      final whole = s(180);
      expect(chunker.feed(whole), [whole]);
    });
  });

  group('markdown 标记成对', () {
    test('切点落在未闭合加粗内部时回退到标记之前', () {
      final head = s(45);
      // 「。」出现在还没闭合的 **…** 内部，切在这里会把星号念出来
      expect(chunker.feed('$head**强调说明。'), [head]);
      final out = chunker.feed('和更多内容**收尾。');
      expect(out, hasLength(1));
      expect(TtsService.cleanSpeechText(out.single, maxChars: null), isNot(contains('*')));
    });

    test('出段内容不含孤立星号，清洗后读起来没有噪音', () {
      final text = '${s(45)}**重点**说明。';
      final out = chunker.feed(text);
      expect(out.single, text);
      expect(TtsService.cleanSpeechText(out.single, maxChars: null), isNot(contains('*')));
    });

    test('未闭合的行内代码被扣住，闭合后完整成段', () {
      final head = s(45);
      expect(chunker.feed('$head调用一下这个方法 `get'), [head]);
      expect(
        chunker.feed('User()` 就可以正常拿到用户资料啦。'),
        ['调用一下这个方法 `getUser()` 就可以正常拿到用户资料啦。'],
      );
    });
  });

  group('代码块围栏', () {
    test('闭合围栏内的代码整段跳过，围栏外文字照常朗读', () {
      final head = s(45);
      final tail = s(45, unit: '结');
      final out = chunker.feed(
        '$head\n```dart\nvar x = 1;\nprint(x);\n```\n$tail\n',
      );
      final spoken = out.join();
      expect(spoken, contains(head));
      expect(spoken, contains(tail));
      expect(spoken, isNot(contains('var x')));
    });

    test('围栏未闭合时代码不会冒出来，收尾时同样丢弃', () {
      final head = s(45);
      expect(chunker.feed('$head\n```dart\nvar x = 1;\n'), [head]);
      expect(chunker.flush(), isEmpty);
    });

    test('围栏标记被 chunk 切断也不误判成代码块', () {
      final head = s(45);
      // 反引号开头的行先扣住，等整行到齐再定性
      expect(chunker.feed('$head\n`'), [head]);
      expect(chunker.feed('``dart\nvar x = 1;\n```\n好的收到。'), isEmpty);
      expect(chunker.flush(), ['好的收到。']);
    });
  });

  group('不变式', () {
    test('逐字符喂与整块喂念出来的字一个字都不少', () {
      final source = '${'第一句内容很多所以要提前开口。' * 4}\n\n'
          '第二项：\n- 甲\n- 乙\n\n最后一句也该念到了。';
      final streamed = <String>[];
      for (var i = 0; i < source.length; i++) {
        streamed.addAll(chunker.feed(source[i]));
      }
      streamed.addAll(chunker.flush());

      final whole = SpeechChunker();
      final blocked = [...whole.feed(source), ...whole.flush()];

      expect(compact(streamed.join()), compact(source));
      expect(compact(blocked.join()), compact(source));
      // 逐 token 到达时更早开口，代价是段更碎
      expect(streamed.length, greaterThanOrEqualTo(blocked.length));
    });

    test('discard 之后既不漏下已扣文字，也重新按首段门槛起算', () {
      chunker.feed('${s(45)}**未闭合');
      chunker.discard();
      expect(chunker.flush(), isEmpty);
      expect(chunker.feed('新一轮正文。'), isEmpty);
    });

    test('isEmpty 反映是否已有可朗读内容（上层据此决定要不要打断播放）', () {
      expect(chunker.isEmpty, isTrue);
      chunker.feed('铺垫文字');
      expect(chunker.isEmpty, isFalse);
    });
  });

  group('与清洗配合', () {
    test('逐段清洗不会被 600 字上限截断出「后文略」', () {
      final long = s(700, unit: '长');
      final segments = [...chunker.feed(long), ...chunker.flush()];
      expect(segments.length, greaterThan(1));
      var spoken = 0;
      for (final seg in segments) {
        final cleaned = TtsService.cleanSpeechText(seg, maxChars: null);
        expect(cleaned, isNot(contains('后文略')));
        spoken += cleaned.length;
      }
      // 分段朗读念的是全文，一个字都没被裁掉
      expect(spoken, long.length);
      // 旧的一次性整段朗读路径仍保留 600 字截断语义
      expect(TtsService.cleanSpeechText(long), contains('后文略'));
    });
  });
}
