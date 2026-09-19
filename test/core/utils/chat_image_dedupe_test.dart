import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_image_dedupe.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 构造一条生图工具结果消息。
ChatMessage _generatedToolMessage(List<String> paths, {bool isError = false}) {
  return ChatMessage(
    role: 'tool',
    content: '已成功生成 ${paths.length} 张图片并保存',
    toolName: 'generate_image',
    isError: isError,
    uiDetails: {'type': 'generate_image', 'paths': paths},
  );
}

void main() {
  group('imageKeyOf 图片键归一', () {
    test('绝对路径与相对路径归一到同一 basename', () {
      final absolute = imageKeyOf(
        '/data/user/0/com.appone.qnote_flutter/app_document/images/ai/7f3a.png',
      );
      final relative = imageKeyOf('/images/ai/7f3a.png');
      expect(absolute, '7f3a.png');
      expect(relative, absolute);
    });

    test('Windows 反斜杠路径同样取文件名', () {
      expect(
        imageKeyOf(r'C:\Users\me\Documents\images\ai\abc.jpg'),
        'abc.jpg',
      );
    });

    test('data URI 用「媒体类型 + 载荷前缀」做指纹，不同类型互不相同', () {
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAf';
      const jpeg =
          'data:image/jpeg;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAf';
      expect(imageKeyOf(png), isNot(imageKeyOf(jpeg)));
    });

    test('空串与首尾空白', () {
      expect(imageKeyOf(''), '');
      expect(imageKeyOf('  /a/b/c.png  '), 'c.png');
    });
  });

  group('collectGeneratedImageKeys 去重集合来源', () {
    test('只收集生图成功卡片的路径键', () {
      final messages = [
        ChatMessage(role: 'user', content: '画一张图'),
        _generatedToolMessage(['/documents/images/ai/one.png']),
        _generatedToolMessage(['/documents/images/ai/bad.png'], isError: true),
        ChatMessage(
          role: 'tool',
          content: 'ok',
          toolName: 'write_file',
          uiDetails: {'paths': ['/notes/x.md']},
        ),
        ChatMessage(role: 'assistant', content: '给你'),
      ];
      final keys = collectGeneratedImageKeys(messages);
      expect(keys, {'one.png'});
    });

    test('多条卡片与重复路径自动合并', () {
      final keys = collectGeneratedImageKeys([
        _generatedToolMessage(['/a/x.png', '/b/y.png']),
        _generatedToolMessage(['/c/x.png']),
      ]);
      expect(keys, {'x.png', 'y.png'});
    });

    test('生图被折叠进工具链时仍能从成员消息收集', () {
      final group = ChatMessage(
        role: 'tool_group',
        content: '',
        uiDetails: {
          'messages': [
            _generatedToolMessage(['/images/ai/in-group.png']),
          ],
        },
      );
      expect(collectGeneratedImageKeys([group]), contains('in-group.png'));
    });

    test('无消息时返回空集合', () {
      expect(collectGeneratedImageKeys(const []), isEmpty);
    });
  });

  group('isRedundantGeneratedImage 正文重复判定', () {
    final keys = {'uuid-1.png'};

    test('卡片路径与正文 src 前缀不同也能命中', () {
      expect(
        isRedundantGeneratedImage('/data/documents/images/ai/uuid-1.png', keys),
        isTrue,
      );
    });

    test('未出现在卡片里的图片不会被误判', () {
      expect(
        isRedundantGeneratedImage('/documents/images/other-9.png', keys),
        isFalse,
      );
    });

    test('去重集合为空时一律不判重', () {
      expect(isRedundantGeneratedImage('/a/b.png', const {}), isFalse);
    });

    test('模型截断回显 data URI 时按前缀仍判为同一张图', () {
      const full =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAf';
      const truncated = 'data:image/png;base64,iVBORw0KGgoAAAANSU';
      expect(
        isRedundantGeneratedImage(truncated, {imageKeyOf(full)}),
        isTrue,
      );
    });

    test('data URI 前缀过短时不判重，避免同类型图片被连带抹掉', () {
      const full = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg';
      expect(
        isRedundantGeneratedImage('data:image/png;base64,iVB', {
          imageKeyOf(full),
        }),
        isFalse,
      );
    });
  });

  group('stripRedundantImageMarkdown 纯文本面板剥离', () {
    final keys = {'gen.png'};

    test('整行只有图片语法时连同该行一起丢弃', () {
      final result = stripRedundantImageMarkdown(
        '这是给你做的图：\n![image](/documents/images/ai/gen.png)',
        keys,
      );
      expect(result, '这是给你做的图：');
    });

    test('原本的空行保留以维持段落间隔', () {
      final result = stripRedundantImageMarkdown(
        '第一段\n\n![image](/x/gen.png)\n\n第二段',
        keys,
      );
      expect(result, '第一段\n\n\n第二段');
    });

    test('非重复图片语法原样保留', () {
      const content = '![image](/documents/images/ai/other.png)';
      expect(stripRedundantImageMarkdown(content, keys), content);
    });

    test('不含图片语法或集合为空时直接返回原文', () {
      expect(stripRedundantImageMarkdown('普通正文', keys), '普通正文');
      expect(stripRedundantImageMarkdown('![a](/x/gen.png)', const {}), '![a](/x/gen.png)');
    });
  });
}
