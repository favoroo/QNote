import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/q_cursor_context.dart';

void main() {
  group('buildCursorContextSnippet', () {
    test('光标居中的短文本：完整摘录、无省略号', () {
      final snippet = buildCursorContextSnippet('hello world', 5);
      expect(snippet, 'hello【光标】 world');
    });

    test('光标在文本开头：只摘录后文、无前缀省略号', () {
      final snippet = buildCursorContextSnippet('abc', 0);
      expect(snippet, '【光标】abc');
    });

    test('光标在文本末尾：只摘录前文、无后缀省略号', () {
      final snippet = buildCursorContextSnippet('abc', 3);
      expect(snippet, 'abc【光标】');
    });

    test('贴近开头：前文完整保留、后文 60 字窗口加省略号', () {
      final text = 'a' * 200;
      final snippet = buildCursorContextSnippet(text, 10);
      expect(snippet, '${'a' * 10}【光标】${'a' * 60}…');
    });

    test('贴近结尾：前文 60 字窗口加省略号、后文完整保留', () {
      final text = 'a' * 200;
      final snippet = buildCursorContextSnippet(text, 190);
      expect(snippet, '…${'a' * 60}【光标】${'a' * 10}');
    });

    test('深处光标：前后各 60 字、两侧都有省略号', () {
      final text = 'x' * 300;
      final snippet = buildCursorContextSnippet(text, 150);
      expect(snippet, '…${'x' * 60}【光标】${'x' * 60}…');
    });

    test('空文本：返回空字符串（空态文案由调用方决定）', () {
      expect(buildCursorContextSnippet('', 0), '');
    });

    test('纯空白文本：返回空字符串', () {
      expect(buildCursorContextSnippet('  \n  ', 2), '');
    });

    test('offset 越界（超末尾）：收敛到文本长度、不抛异常', () {
      final snippet = buildCursorContextSnippet('abc', 100);
      expect(snippet, 'abc【光标】');
    });

    test('offset 越界（负数）：收敛到 0', () {
      final snippet = buildCursorContextSnippet('abc', -5);
      expect(snippet, '【光标】abc');
    });

    test('自定义 contextChars：按指定窗口截取', () {
      final snippet = buildCursorContextSnippet('abcdef', 3, contextChars: 2);
      expect(snippet, '…bc【光标】de…');
    });
  });
}
