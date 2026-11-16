import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/note_file_type.dart';

void main() {
  group('NoteFileTypeHelper.fromTitle', () {
    test('HTML 网页（含大小写与 htm 变体）', () {
      expect(NoteFileTypeHelper.fromTitle('xiaop.html'), NoteFileType.html);
      expect(NoteFileTypeHelper.fromTitle('页面.HTML'), NoteFileType.html);
      expect(NoteFileTypeHelper.fromTitle('index.htm'), NoteFileType.html);
    });

    test('SVG 矢量图', () {
      expect(NoteFileTypeHelper.fromTitle('logo.svg'), NoteFileType.svg);
      expect(NoteFileTypeHelper.fromTitle('图表.SVG'), NoteFileType.svg);
    });

    test('Mermaid 图（mmd / mermaid，含大小写）', () {
      expect(NoteFileTypeHelper.fromTitle('架构图.mmd'), NoteFileType.mermaid);
      expect(NoteFileTypeHelper.fromTitle('时序.MMD'), NoteFileType.mermaid);
      expect(NoteFileTypeHelper.fromTitle('flow.mermaid'), NoteFileType.mermaid);
    });

    test('CSV/TSV 表格', () {
      expect(NoteFileTypeHelper.fromTitle('账单.csv'), NoteFileType.csv);
      expect(NoteFileTypeHelper.fromTitle('数据.CSV'), NoteFileType.csv);
      expect(NoteFileTypeHelper.fromTitle('导出.tsv'), NoteFileType.csv);
    });

    test('JSON 数据文件', () {
      expect(NoteFileTypeHelper.fromTitle('stats.json'), NoteFileType.json);
    });

    test('常见代码文件', () {
      expect(NoteFileTypeHelper.fromTitle('main.py'), NoteFileType.code);
      expect(NoteFileTypeHelper.fromTitle('style.css'), NoteFileType.code);
      expect(NoteFileTypeHelper.fromTitle('app.js'), NoteFileType.code);
      expect(NoteFileTypeHelper.fromTitle('query.sql'), NoteFileType.code);
      expect(NoteFileTypeHelper.fromTitle('config.yml'), NoteFileType.code);
      expect(NoteFileTypeHelper.fromTitle('note.dart'), NoteFileType.code);
    });

    test('Markdown 与无后缀标题保持默认类型', () {
      expect(NoteFileTypeHelper.fromTitle('网页版自我介绍说明.md'), NoteFileType.markdown);
      expect(NoteFileTypeHelper.fromTitle('无标题'), NoteFileType.markdown);
      expect(NoteFileTypeHelper.fromTitle('2026-09-12 记录'), NoteFileType.markdown);
    });

    test('未识别的后缀视为 Markdown（不误判）', () {
      expect(NoteFileTypeHelper.fromTitle('报告.docx'), NoteFileType.markdown);
      expect(NoteFileTypeHelper.fromTitle('版本 v1.0'), NoteFileType.markdown);
      expect(NoteFileTypeHelper.fromTitle('结尾有点.'), NoteFileType.markdown);
    });
  });

  group('NoteFileTypeHelper.isCodeLike', () {
    test('仅 Markdown 不是源码类，其余均按源码处理', () {
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.markdown), isFalse);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.html), isTrue);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.svg), isTrue);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.mermaid), isTrue);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.csv), isTrue);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.json), isTrue);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.code), isTrue);
    });
  });

  group('NoteFileTypeHelper 扩展名辅助', () {
    test('extensionOf 取小写后缀，无后缀返回 null', () {
      expect(NoteFileTypeHelper.extensionOf('架构图.mmd'), 'mmd');
      expect(NoteFileTypeHelper.extensionOf('账单.CSV'), 'csv');
      expect(NoteFileTypeHelper.extensionOf('无后缀笔记'), isNull);
      expect(NoteFileTypeHelper.extensionOf('结尾有点.'), isNull);
    });

    test('hasRecognizedExtension 覆盖文档与代码后缀', () {
      expect(NoteFileTypeHelper.hasRecognizedExtension('架构图.mmd'), isTrue);
      expect(NoteFileTypeHelper.hasRecognizedExtension('账单.csv'), isTrue);
      expect(NoteFileTypeHelper.hasRecognizedExtension('页面.html'), isTrue);
      expect(NoteFileTypeHelper.hasRecognizedExtension('main.py'), isTrue);
      // 未识别后缀 / 无后缀：VFS 需要补 `.md`，不能误判为已带后缀
      expect(NoteFileTypeHelper.hasRecognizedExtension('报告.docx'), isFalse);
      expect(NoteFileTypeHelper.hasRecognizedExtension('会议纪要 2.0'), isFalse);
    });

    test('supportsPreview / prefersPreviewByDefault', () {
      expect(NoteFileTypeHelper.supportsPreview(NoteFileType.mermaid), isTrue);
      expect(NoteFileTypeHelper.supportsPreview(NoteFileType.csv), isTrue);
      // `.json` 已不做专属预览：移动端树视图没有实际价值，打开即源码
      expect(NoteFileTypeHelper.supportsPreview(NoteFileType.json), isFalse);
      expect(NoteFileTypeHelper.supportsPreview(NoteFileType.code), isFalse);
      expect(NoteFileTypeHelper.supportsPreview(NoteFileType.markdown), isFalse);
      expect(NoteFileTypeHelper.prefersPreviewByDefault(NoteFileType.html), isTrue);
      expect(NoteFileTypeHelper.prefersPreviewByDefault(NoteFileType.markdown), isFalse);
    });
  });
}
