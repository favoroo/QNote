import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/note_segments.dart';

/// 把分段压成易读的简写，便于整表断言：
/// `t:文本` / `i:路径` / `l:url` / `l:标题|url`
List<String> _shape(List<NoteSegmentData> segments) => segments.map((s) {
  switch (s.type) {
    case NoteSegmentType.text:
      return 't:${s.text}';
    case NoteSegmentType.image:
      return 'i:${s.path}';
    case NoteSegmentType.link:
      return s.title == null ? 'l:${s.url}' : 'l:${s.title}|${s.url}';
  }
}).toList();

void main() {
  group('parseNoteSegments 基础语法', () {
    test('纯文本整体作为单个文本段', () {
      final segments = parseNoteSegments('第一行\n第二行');

      expect(_shape(segments), ['t:第一行\n第二行']);
    });

    test('单图片：两侧文本 + 图片，末尾补文本段', () {
      final segments = parseNoteSegments('上面的字\n![image](a/b.png)');

      expect(_shape(segments), ['t:上面的字', 'i:a/b.png', 't:']);
    });

    test('单链接（Markdown 语法）保留标题', () {
      final segments = parseNoteSegments('见[某站](https://example.com/a)吧');

      expect(_shape(segments), ['t:见', 'l:某站|https://example.com/a', 't:吧']);
    });

    test('裸链接按 URL 切出独立链接段', () {
      final segments = parseNoteSegments('看 https://example.com/x 了');

      expect(_shape(segments), ['t:看 ', 'l:https://example.com/x', 't: 了']);
    });

    test('图片与链接混排', () {
      const content = '开头[站点](https://a.com)\n![image](p1.png)\n中间 https://b.com 结尾';

      expect(_shape(parseNoteSegments(content)), [
        't:开头',
        'l:站点|https://a.com',
        'i:p1.png',
        't:中间 ',
        'l:https://b.com',
        't: 结尾',
      ]);
    });

    test('图片说明文字被忽略，路径原样保留', () {
      final segments = parseNoteSegments('![截图说明](/tmp/图 1.png)');

      expect(_shape(segments), ['t:', 'i:/tmp/图 1.png', 't:']);
    });
  });

  group('URL 切分细节', () {
    test('连续两个 URL 之间保留空格文本段', () {
      final segments = parseNoteSegments('https://a.com https://b.com');

      expect(_shape(segments), ['l:https://a.com', 't: ', 'l:https://b.com', 't:']);
    });

    test('URL 紧贴中文：中文不被吞进链接', () {
      final segments = parseNoteSegments('看这个https://a.com很好');

      expect(_shape(segments), ['t:看这个', 'l:https://a.com', 't:很好']);
    });

    test('URL 后带标点：标点切为独立文本段', () {
      final segments = parseNoteSegments('见 https://a.com/path.');

      expect(_shape(segments), ['t:见 ', 'l:https://a.com/path', 't:.']);
    });

    test('URL 尾部多个标点一起剥离，标点段即末段', () {
      final segments = parseNoteSegments('https://a.com?!');

      // 标点段本身已是文本段，不再额外补空文本段
      expect(_shape(segments), ['l:https://a.com', 't:?!']);
    });

    test('Markdown 链接的 URL 不剥离尾部标点（括号外标点单独成段）', () {
      final segments = parseNoteSegments('[标题](https://a.com).');

      expect(_shape(segments), ['l:标题|https://a.com', 't:.']);
    });

    test('splitNoteTextByLinks 的 lastMatchIndex 指向匹配产出的最后一段', () {
      final result = splitNoteTextByLinks('前缀 https://a.com.');

      expect(_shape(result.segments), ['t:前缀 ', 'l:https://a.com', 't:.']);
      // 末尾标点也算匹配产出，与编辑器恢复焦点的历史口径一致
      expect(result.lastMatchIndex, 2);
    });

    test('splitNoteTextByLinks 无链接时 lastMatchIndex 为 -1', () {
      final result = splitNoteTextByLinks('纯文本');

      expect(_shape(result.segments), ['t:纯文本']);
      expect(result.lastMatchIndex, -1);
    });

    test('hasNoteLinks 只认 Markdown 链接与 http(s) 裸链接', () {
      expect(hasNoteLinks('https://a.com'), isTrue);
      expect(hasNoteLinks('[a](http://b.cn)'), isTrue);
      expect(hasNoteLinks('ftp://a.com'), isFalse);
      expect(hasNoteLinks('纯文本'), isFalse);
    });
  });

  group('parseNoteSegments 空内容与结构保证', () {
    test('空内容得到一个空文本段', () {
      expect(_shape(parseNoteSegments('')), ['t:']);
    });

    test('只有空白：尾部空白被裁掉，只留空文本段', () {
      // 末尾的 trimLeft/trimRight 会把纯空白内容裁空
      expect(_shape(parseNoteSegments('   ')), ['t:']);
      expect(_shape(parseNoteSegments('\n\n')), ['t:']);
      expect(_shape(parseNoteSegments('  \n  ')), ['t:']);
    });

    test('以链接结尾时补一个空文本段', () {
      expect(_shape(parseNoteSegments('https://a.com')), ['l:https://a.com', 't:']);
      expect(_shape(parseNoteSegments('[a](https://b.com)')), ['l:a|https://b.com', 't:']);
    });

    test('plainCode 模式整体作为单段，不解析图片与链接', () {
      const content = '<img src="x">\n![image](p.png)\nhttps://a.com';
      final segments = parseNoteSegments(content, plainCode: true);

      expect(_shape(segments), ['t:$content']);
    });
  });

  group('serializeNoteSegments 往返一致性', () {
    test('多段落与空行原样保留（无图片/链接）', () {
      const content = '第一段\n\n第二段\n\n\n第三段';

      expect(serializeNoteSegments(parseNoteSegments(content)), content);
    });

    test('图片单行换行结构可完整往返', () {
      const content = '开头\n![image](p1.png)\n结尾';

      expect(serializeNoteSegments(parseNoteSegments(content)), content);
    });

    test('多图片往返', () {
      const content = '![image](a.png)\n![image](b.png)\n文字';

      expect(serializeNoteSegments(parseNoteSegments(content)), content);
    });

    test('链接独占一行：已知非幂等（历史行为，每轮多一个尾换行）', () {
      // 链接段自带尾换行，剩余的 '\n' 又被保留成文本段，所以反复「解析→序列化」
      // 会逐轮累加换行。这里锁住现状，避免重构悄悄改变存储格式。
      const content = '[站点](https://a.com)\n';
      final first = serializeNoteSegments(parseNoteSegments(content));
      final second = serializeNoteSegments(parseNoteSegments(first));

      expect(first, '[站点](https://a.com)\n\n');
      expect(second, '[站点](https://a.com)\n\n\n');
    });

    test('链接与正文混排按现有规则分行输出（链接各占一行）', () {
      // 历史行为：序列化时每个链接都补尾换行，因此不会逐字还原原文；
      // 这里锁住实际输出，避免重构时无意改变存储格式
      final segments = parseNoteSegments('[站点](https://a.com)\nhttps://b.com');

      expect(serializeNoteSegments(segments), '[站点](https://a.com)\n\n\nhttps://b.com\n');
    });

    test('图片两侧空行按现有规则折叠，二次序列化稳定', () {
      const content = 'a\n\n![image](p.png)\n\nb';
      final first = serializeNoteSegments(parseNoteSegments(content));
      final second = serializeNoteSegments(parseNoteSegments(first));

      expect(first, 'a\n![image](p.png)\nb');
      expect(second, first);
    });

    test('空内容序列化为空字符串', () {
      expect(serializeNoteSegments(parseNoteSegments('')), '');
      expect(serializeNoteSegments(const []), '');
    });

    test('链接无标题时输出裸 URL', () {
      final segments = [const NoteSegmentData.text('看 '), const NoteSegmentData.link(url: 'https://a.com')];

      // 非末段文本会补一个换行，链接本身也带尾换行
      expect(serializeNoteSegments(segments), '看 \nhttps://a.com\n');
    });
  });

  group('extractImagePaths', () {
    test('按出现顺序提取，且不去重', () {
      final segments = parseNoteSegments('![image](a.png)\n![image](b.png)\n![image](a.png)');

      expect(extractImagePaths(segments), ['a.png', 'b.png', 'a.png']);
    });

    test('无图片返回空列表', () {
      expect(extractImagePaths(parseNoteSegments('只有文字')), isEmpty);
    });
  });

  group('normalizeNoteTitle', () {
    test('空标题归一为「无标题」', () {
      expect(normalizeNoteTitle(''), '无标题');
    });

    test('非空标题原样保留（含纯空白）', () {
      expect(normalizeNoteTitle('我的笔记'), '我的笔记');
      expect(normalizeNoteTitle('  '), '  ');
    });
  });

  group('mergeNoteText', () {
    test('前段以换行结尾时直接相接', () {
      expect(mergeNoteText('上一段\n', '下一段'), '上一段\n下一段');
    });

    test('前段无换行时补一个换行', () {
      expect(mergeNoteText('上一段', '下一段'), '上一段\n下一段');
    });
  });

  group('相等比较', () {
    test('noteSegmentsEqual 逐段比较类型与字段', () {
      final a = parseNoteSegments('a https://x.com');
      final b = parseNoteSegments('a https://x.com');
      final c = parseNoteSegments('a https://y.com');

      expect(noteSegmentsEqual(a, b), isTrue);
      expect(noteSegmentsEqual(a, c), isFalse);
      expect(noteSegmentsEqual(a, [...a, const NoteSegmentData.text('')]), isFalse);
    });

    test('同类型不同字段视为不相等', () {
      expect(
        noteSegmentsEqual(
          [const NoteSegmentData.link(url: 'https://a.com', title: 'a')],
          [const NoteSegmentData.link(url: 'https://a.com')],
        ),
        isFalse,
      );
      expect(noteSegmentsEqual([const NoteSegmentData.image('a.png')], [const NoteSegmentData.text('a.png')]), isFalse);
    });

    test('stringListsEqual 顺序敏感', () {
      expect(stringListsEqual(['a', 'b'], ['a', 'b']), isTrue);
      expect(stringListsEqual(['a', 'b'], ['b', 'a']), isFalse);
      expect(stringListsEqual(['a'], ['a', 'b']), isFalse);
      expect(stringListsEqual([], []), isTrue);
    });
  });
}
