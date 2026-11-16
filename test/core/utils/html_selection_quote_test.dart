import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_text_quote.dart';
import 'package:qnote_flutter/core/utils/html_selection_quote.dart';

void main() {
  group('HtmlSelectionPayload 解析', () {
    test('解析文字选区 payload（含元素与位置信息）', () {
      final payload = HtmlSelectionPayload.tryParse('''
{
  "token": "abc123",
  "kind": "text",
  "selector": "body > main > section.card:nth-of-type(2)",
  "tag": "SECTION",
  "id": "today",
  "classes": ["card", "today-plan"],
  "text": "今天别再踩",
  "html": "<section class=\\"card today-plan\\" id=\\"today\\">今天别再踩</section>",
  "ancestors": "body > main",
  "rect": {"x": 16, "y": 420, "w": 343, "h": 210},
  "scroll": {"x": 0, "y": 120},
  "viewport": {"w": 375, "h": 812},
  "url": "https://note-12.qnote.local/",
  "pageTitle": "今日处方"
}
''');

      expect(payload, isNotNull);
      expect(payload!.isElement, isFalse);
      expect(payload.tagName, 'section');
      expect(payload.elementId, 'today');
      expect(payload.classNames, ['card', 'today-plan']);
      expect(payload.text, '今天别再踩');
      expect(payload.outerHtml, contains('<section'));
      expect(payload.rect!.x, 16);
      expect(payload.rect!.width, 343);
      expect(payload.viewport!.width, 375);
      expect(payload.token, 'abc123');
      expect(payload.shortLabel, 'section#today.card.today-plan');
    });

    test('元素选择 kind=element', () {
      final payload = HtmlSelectionPayload.tryParse(
        '{"kind":"element","tag":"div","selector":"#hero","id":"hero","classes":["hero"],"text":"欢迎"}',
      );
      expect(payload, isNotNull);
      expect(payload!.isElement, isTrue);
      expect(payload.shortLabel, 'div#hero.hero');
    });

    test('非法 JSON / 信息过少时返回 null', () {
      expect(HtmlSelectionPayload.tryParse(''), isNull);
      expect(HtmlSelectionPayload.tryParse('not json'), isNull);
      expect(HtmlSelectionPayload.tryParse('[]'), isNull);
      expect(HtmlSelectionPayload.tryParse('{"kind":"text"}'), isNull);
    });

    test('缺少 id/classes 等可选字段不报错', () {
      final payload = HtmlSelectionPayload.tryParse('{"kind":"text","tag":"p","text":"一段文字"}');
      expect(payload, isNotNull);
      expect(payload!.elementId, isNull);
      expect(payload.classNames, isEmpty);
      expect(payload.rect, isNull);
    });
  });

  group('源码行号定位', () {
    const source = '''
<!DOCTYPE html>
<html>
<head><style>.card { color: red; }</style></head>
<body>
  <main>
    <section class="card today" id="hero">
      <h1>昨天那个坑</h1>
    </section>
    <section class="card">
      <p>今天别再踩</p>
    </section>
  </main>
  <script>var s = '<section class="card">fake</section>';</script>
</body>
</html>
''';

    test('优先按 id 精确定位', () {
      final hints = locateHtmlElementInSource(source, tagName: 'section', elementId: 'hero');
      expect(hints.openTags, hasLength(1));
      expect(hints.openTags.first.line, 6);
      expect(hints.openTags.first.snippet, contains('id="hero"'));
    });

    test('按 class 定位并屏蔽脚本内的假标签', () {
      final hints = locateHtmlElementInSource(source, tagName: 'section', classNames: ['card']);
      expect(hints.openTags.map((m) => m.line), [6, 9]);
    });

    test('无 id/class 时退回标签名匹配', () {
      final hints = locateHtmlElementInSource(source, tagName: 'section');
      expect(hints.openTags.map((m) => m.line), [6, 9]);
    });

    test('选中文字的候选行（含 DOM 渲染文本与源码一致的场景）', () {
      final hints = locateHtmlElementInSource(source, tagName: 'p', text: '今天别再踩');
      expect(hints.textLines, [10]);
    });

    test('标签名非法或为空时安全返回', () {
      expect(locateHtmlElementInSource(source, tagName: '').openTags, isEmpty);
      expect(locateHtmlElementInSource(source, tagName: 'section on').openTags, isEmpty);
    });
  });

  group('组装「给小Q」引用', () {
    const source = '''
<html>
<body>
  <main>
    <section class="card" id="today">
      <h1>昨天那个坑</h1>
      <p>今天别再踩</p>
    </section>
  </main>
</body>
</html>
''';

    test('文字选区引用带上元素信息、源码候选行与位置描述', () {
      final payload = HtmlSelectionPayload.tryParse('''
{
  "kind": "text",
  "selector": "body > main > section.card",
  "tag": "section",
  "id": "today",
  "classes": ["card"],
  "text": "今天别再踩",
  "html": "<section class=\\"card\\" id=\\"today\\"><h1>昨天那个坑</h1><p>今天别再踩</p></section>",
  "ancestors": "body > main",
  "rect": {"x": 10, "y": 200, "w": 300, "h": 80},
  "viewport": {"w": 375, "h": 812},
  "url": "https://note-1.qnote.local/"
}
''');
      final quote = buildHtmlSelectionQuote(payload: payload!, noteId: '12', noteTitle: '今日处方', sourceHtml: source);

      expect(quote.source, QQuoteSource.note);
      expect(quote.sourceId, '12');
      expect(quote.sourceTitle, '今日处方');
      expect(quote.quotedText, '今天别再踩');
      expect(quote.locationDesc, contains('网页预览'));
      expect(quote.locationDesc, contains('section#today.card'));
      expect(quote.locationDesc, contains('第 4 行'));
      expect(quote.webElement, isNotNull);
      expect(quote.webElement!.selector, contains('section.card'));
      expect(quote.webElement!.sourceLines, [4]);
      expect(quote.webElement!.textLines, [6]);
      expect(quote.webElement!.rect!.width, 300);
    });

    test('元素选择无文本时用 outerHTML 作为引用摘要', () {
      final payload = HtmlSelectionPayload.tryParse(
        '{"kind":"element","tag":"section","classes":["card"],"html":"<section class=\\"card\\"></section>"}',
      );
      final quote = buildHtmlSelectionQuote(
        payload: payload!,
        noteId: '1',
        noteTitle: '卡片页',
        sourceHtml: '<html><body><section class="card"></section></body></html>',
      );
      expect(quote.quotedText, contains('<section class="card"></section>'));
      expect(quote.locationDesc, contains('第 1 行'));
      expect(quote.webElement!.renderedText, isNull);
    });

    test('源码中找不到元素时仍有可注入的引用', () {
      final payload = HtmlSelectionPayload.tryParse('{"kind":"text","tag":"div","text":"动态生成的内容"}');
      final quote = buildHtmlSelectionQuote(
        payload: payload!,
        noteId: '2',
        noteTitle: '动态页',
        sourceHtml: '<html><body><p>动态生成的内容</p></body></html>',
      );
      expect(quote.quotedText, '动态生成的内容');
      expect(quote.webElement!.sourceLines, isEmpty);
      expect(quote.locationDesc, contains('按文本匹配'));
      expect(quote.locationDesc, contains('第 1 行（按文本匹配）'));
    });

    test('超长引用与 outerHTML 截断', () {
      final payload = HtmlSelectionPayload.tryParse(
        '{"kind":"text","tag":"div","text":"${'长' * 2500}","html":"${'<span>' * 2000}"}',
      );
      final quote = buildHtmlSelectionQuote(payload: payload!, noteId: '3', noteTitle: '长页', sourceHtml: '<div></div>');
      expect(quote.quotedText.length, lessThan(2100));
      expect(quote.quotedText, endsWith('…（已截断）'));
      expect(quote.webElement!.outerHtml!.length, lessThan(6100));
      expect(quote.webElement!.outerHtml, endsWith('…（已截断）'));
    });
  });
}
