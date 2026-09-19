import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/tts/tts_service.dart';

void main() {
  group('TtsService.cleanSpeechText', () {
    test('剔除围栏代码块', () {
      const raw = '看这段代码：\n```dart\nprint("hello");\n```\n运行即可。';
      final text = TtsService.cleanSpeechText(raw);
      expect(text, contains('看这段代码'));
      expect(text, contains('运行即可'));
      expect(text, isNot(contains('print')));
      expect(text, isNot(contains('```')));
    });

    test('行内代码去反引号', () {
      expect(TtsService.cleanSpeechText('用 `print` 函数'), '用 print 函数');
    });

    test('链接仅保留文字、图片与裸 URL 剔除', () {
      final text = TtsService.cleanSpeechText(
        '看[文档](https://example.com/a)和![图](https://x.com/y.png)以及 https://a.com/b',
      );
      expect(text, contains('文档'));
      expect(text, isNot(contains('example.com')));
      expect(text, isNot(contains('y.png')));
      expect(text, isNot(contains('a.com/b')));
    });

    test('加粗/斜体/删除线标记剥离', () {
      expect(TtsService.cleanSpeechText('**重要**的*提示*，~~别忘~~了'), '重要的提示，别忘了');
    });

    test('标题/引用/列表前缀剥离并保留正文', () {
      final text = TtsService.cleanSpeechText('# 标题\n> 引用内容\n- 第一点\n2. 第二点');
      expect(text, contains('标题'));
      expect(text, contains('引用内容'));
      expect(text, contains('第一点'));
      expect(text, contains('第二点'));
      expect(text, isNot(contains('#')));
      expect(text, isNot(contains('>')));
      expect(text, isNot(contains('- ')));
    });

    test('表格分隔行剔除、竖线去除', () {
      final text = TtsService.cleanSpeechText('| 名称 | 值 |\n| --- | --- |\n| 甲 | 1 |');
      expect(text, contains('名称'));
      expect(text, contains('甲'));
      expect(text, isNot(contains('|')));
      expect(text, isNot(contains('---')));
    });

    test('emoji 与杂类符号剔除', () {
      final text = TtsService.cleanSpeechText('好的😀，完成✅');
      expect(text, '好的，完成');
    });

    test('连续空白折叠为单个空格', () {
      expect(TtsService.cleanSpeechText('你好\n\n\n   世界'), '你好 世界');
    });

    test('超长文本按句子边界截断并带省略提示', () {
      final sentence = '这是一句完整的测试文本。' * 80; // 远超 600 字
      final text = TtsService.cleanSpeechText(sentence);
      expect(text.length, lessThan(700));
      expect(text, endsWith('……后文略。'));
      expect(text, isNot(contains('。后文略。后文略')));
    });

    test('清洗后为空返回空串', () {
      expect(TtsService.cleanSpeechText('```\nonly code\n```'), isEmpty);
    });

    test('音色目录查询：未知 ID 回退默认', () {
      expect(TtsService.voiceById('nonexistent').id, TtsService.defaultVoice);
      expect(TtsService.voiceById('zh-CN-YunxiNeural').label, '云希');
    });
  });
}
