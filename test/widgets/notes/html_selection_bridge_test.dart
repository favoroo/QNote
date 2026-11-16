import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/notes/html_preview/html_selection_bridge.dart';

void main() {
  group('HtmlSelectionBridge.prepareHtml', () {
    test('在 </body> 前注入选择探针并替换 token', () {
      final result = HtmlSelectionBridge.prepareHtml('<html><body><h1>卡片</h1></body></html>', token: 'abc-123');

      expect(result, contains('<script id="${HtmlSelectionBridge.marker}">'));
      expect(result, contains("var TOKEN = 'abc-123';"));
      expect(result, contains('__qnoteHtmlSelectionInitialized'));
      expect(result, contains('QNoteHtmlSelection'));
      // 注入点应位于 </body> 之前
      expect(result.indexOf(HtmlSelectionBridge.marker), lessThan(result.indexOf('</body>')));
    });

    test('重复注入不会叠加脚本', () {
      final once = HtmlSelectionBridge.prepareHtml('<body>x</body>', token: 't1');
      final twice = HtmlSelectionBridge.prepareHtml(once, token: 't2');
      expect(twice, same(once));
      expect(RegExp(HtmlSelectionBridge.marker).allMatches(twice).length, 1);
    });

    test('没有 body 时挂到 </html> 前', () {
      final result = HtmlSelectionBridge.prepareHtml('<html><h1>x</h1></html>', token: 't');
      expect(result.indexOf(HtmlSelectionBridge.marker), lessThan(result.indexOf('</html>')));
    });

    test('没有任何闭合标签时追加到末尾', () {
      final result = HtmlSelectionBridge.prepareHtml('<h1>x</h1>', token: 't');
      expect(result, endsWith('</script>'));
    });

    test('脚本字符串中的假 </body> 不作为注入点', () {
      const source = '<html><body><script>var s = "</body>";</script></body></html>';
      final result = HtmlSelectionBridge.prepareHtml(source, token: 't');
      expect(result.indexOf(HtmlSelectionBridge.marker), greaterThan(result.indexOf('var s')));
      expect(result.endsWith('</script>\n</body></html>'), isTrue);
    });

    test('token 只保留字母数字与连字符，避免脚本字符串被破坏', () {
      final result = HtmlSelectionBridge.prepareHtml('<body>x</body>', token: "a b'c<script>");
      expect(result, contains("var TOKEN = 'abcscript';"));
      expect(result, isNot(contains("TOKEN = 'a b")));
    });
  });
}
