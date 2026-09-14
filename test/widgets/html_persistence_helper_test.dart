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
  });
}
