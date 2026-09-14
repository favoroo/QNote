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
      expect(
        NoteFileTypeHelper.fromTitle('网页版自我介绍说明.md'),
        NoteFileType.markdown,
      );
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
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.json), isTrue);
      expect(NoteFileTypeHelper.isCodeLike(NoteFileType.code), isTrue);
    });
  });
}
