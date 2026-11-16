import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/notes/html_preview/html_persistence_helper.dart';

void main() {
  group('HtmlPersistenceHelper', () {
    test('getBaseUrl creates isolated, sanitized subdomains', () {
      expect(HtmlPersistenceHelper.getBaseUrl('123'), 'https://note-123.qnote.local/');
      expect(HtmlPersistenceHelper.getBaseUrl('note_abc_456'), 'https://note-note-abc-456.qnote.local/');
      expect(HtmlPersistenceHelper.getBaseUrl(null), 'https://note-local.qnote.local/');
      expect(HtmlPersistenceHelper.getBaseUrl(''), 'https://note-local.qnote.local/');
      expect(HtmlPersistenceHelper.getBaseUrl('特殊*&字符!@#'), 'https://note-local.qnote.local/');
    });

    test('prepareHtml injects auto persist script before </body> if present', () {
      const source = '<html><body><h1>Hello</h1></body></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source);
      expect(result.contains('__qnote_auto_persist_script'), isTrue);
      expect(result.endsWith('</body></html>'), isTrue);
    });

    test('prepareHtml injects auto persist script before </head> if no body tag', () {
      const source = '<html><head><title>Test</title></head></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source);
      expect(result.contains('__qnote_auto_persist_script'), isTrue);
      expect(result.contains('</head></html>'), isTrue);
    });

    test('prepareHtml does not duplicate script if already present', () {
      const source = '<html><body><script id="__qnote_auto_persist_script"></script></body></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source);
      expect('__qnote_auto_persist_script'.allMatches(result).length, equals(1));
    });

    test('prepareHtml keeps empty storage namespace by default (mobile compat)', () {
      const source = '<html><body><h1>Hello</h1></body></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source);
      expect(result.contains("STORAGE_NS = '';"), isTrue);
      expect(result.contains('__QNOTE_STORAGE_NS__'), isFalse);
    });

    test('prepareHtml injects sanitized per-note storage namespace', () {
      const source = '<html><body><h1>Hello</h1></body></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source, storageNamespace: '42');
      expect(result.contains("STORAGE_NS = '42__';"), isTrue);

      final sanitized = HtmlPersistenceHelper.prepareHtml(source, storageNamespace: 'A#B_c_1');
      expect(sanitized.contains("STORAGE_NS = 'a-b-c-1__';"), isTrue);

      final invalid = HtmlPersistenceHelper.prepareHtml(source, storageNamespace: '***');
      expect(invalid.contains("STORAGE_NS = '';"), isTrue);
    });

    test('prepareHtml 不把脚本字符串里的假 </body> 当作注入点', () {
      const source = '<html><body><script>var s = "</body>";</script></body></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source);
      // 注入点应位于页面脚本之后、真正的 </body> 之前，不能插进脚本字符串里
      expect(result.indexOf('__qnote_auto_persist_script'), greaterThan(result.indexOf('var s')));
      expect(result.endsWith('</body></html>'), isTrue);
    });

    test('auto persist script contains scroll persistence logic', () {
      const source = '<html><body><h1>Hello</h1></body></html>';
      final result = HtmlPersistenceHelper.prepareHtml(source);
      expect(result.contains('__qnote_scroll_v1__'), isTrue);
      expect(result.contains('data-no-scroll-persist'), isTrue);
    });
  });
}
