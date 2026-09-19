import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/storage/chat_storage_usage.dart';
import 'package:qnote_flutter/core/utils/chat_image_refs.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 构造一条生图工具结果消息（路径落在 images/ai/ 下）。
ChatMessage _generatedToolMessage(List<String> paths) {
  return ChatMessage(
    role: 'tool',
    content: '已生成 ${paths.length} 张图片',
    toolName: 'generate_image',
    uiDetails: {'type': 'generate_image', 'paths': paths},
  );
}

ChatSession _session(String id, List<ChatMessage> messages) {
  return ChatSession(
    id: id,
    title: '测试对话',
    messages: messages,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

void main() {
  group('extractChatAiImageKeys 生成图片路径抽取', () {
    test('命中 POSIX 绝对路径里的 images/ai 文件', () {
      final json = jsonEncode([
        {
          'paths': [
            '/data/user/0/com.appone.qnote_flutter/app_document/images/ai/7f3a.png',
          ],
        },
      ]);
      expect(extractChatAiImageKeys(json), {'7f3a.png'});
    });

    test('命中 JSON 转义后的 Windows 反斜杠路径', () {
      // 实际入库形态：路径里的 `\` 被 jsonEncode 转义成 `\\`
      final escaped = r'{"p":"C:\data\images\\ai\\ab-1.jpeg"}';
      expect(extractChatAiImageKeys(escaped), {'ab-1.jpeg'});
    });

    test('文件名归一为小写 basename，便于与目录实际文件比对', () {
      expect(
        extractChatAiImageKeys('/x/images/ai/A1B2.PNG 和 /y/images/ai/A1B2.PNG'),
        {'a1b2.png'},
      );
    });

    test('data URI、网络外链与相册路径都不参与回收', () {
      const other =
          '{"images":["data:image/png;base64,iVBORw0KGgoAAAA",'
          '"https://cdn.example.com/a.png",'
          '"/storage/emulated/0/DCIM/Camera/IMG_0001.png",'
          '"/data/user/0/com.app/files/Pictures/IMG_2.png"]}';
      expect(extractChatAiImageKeys(other), isEmpty);
    });

    test('images/note 与 images/diary 目录下的文件不属于生图回收范围', () {
      expect(
        extractChatAiImageKeys('/x/images/note/n1.png /x/images/diary/d2.jpg'),
        isEmpty,
      );
    });

    test('空文本与 null 返回空集合', () {
      expect(extractChatAiImageKeys(null), isEmpty);
      expect(extractChatAiImageKeys(''), isEmpty);
    });
  });

  group('sessionAiImageKeys 会话级抽取', () {
    test('生图卡片与正文 markdown 指向同一张图时只计一次', () {
      const path = '/app_document/images/ai/shared.png';
      final session = _session('s1', [
        ChatMessage(role: 'user', content: '画一张图'),
        _generatedToolMessage([path]),
        ChatMessage(role: 'assistant', content: '给你：![image]($path)'),
      ]);
      expect(sessionAiImageKeys(session), {'shared.png'});
    });

    test('多张生成图全部收集', () {
      final session = _session('s2', [
        _generatedToolMessage([
          '/a/images/ai/one.png',
          '/a/images/ai/two.webp',
        ]),
      ]);
      expect(sessionAiImageKeys(session), {'one.png', 'two.webp'});
    });
  });

  group('countSessionImageRefs 可见图片计数', () {
    test('附件 + 生图卡片 + 正文 markdown 三处来源合并去重', () {
      const generated = '/app/images/ai/gen.png';
      const attached = '/storage/emulated/0/DCIM/IMG_1.jpg';
      final session = _session('s3', [
        ChatMessage(role: 'user', content: '看这张', images: [attached]),
        _generatedToolMessage([generated]),
        ChatMessage(role: 'assistant', content: '原图：$attached 生成：$generated'),
        ChatMessage(role: 'assistant', content: '再看一次 ![x]($generated)'),
      ]);
      // attached 与 generated 各一张：正文重复引用不叠加计数
      expect(countSessionImageRefs(session), 2);
    });

    test('无图会话计数为 0', () {
      final session = _session(
        's4',
        [ChatMessage(role: 'user', content: '你好')],
      );
      expect(countSessionImageRefs(session), 0);
    });

    test('data URI 与文件路径不会被算作同一张图', () {
      final session = _session('s5', [
        ChatMessage(
          role: 'user',
          content: '',
          images: ['data:image/png;base64,AAA', '/x/images/ai/bbb.png'],
        ),
      ]);
      expect(countSessionImageRefs(session), 2);
    });
  });

  group('summarizeMessageRefs 从 messages 列原文统计', () {
    test('统计消息条数与可见图片数', () {
      final session = _session('s6', [
        ChatMessage(role: 'user', content: '画两张图'),
        _generatedToolMessage(['/x/images/ai/p1.png', '/x/images/ai/p2.png']),
      ]);
      final raw = session.toMap()['messages'] as String;
      final summary = summarizeMessageRefs(raw);
      expect(summary.messageCount, 2);
      expect(summary.imageRefCount, 2);
    });

    test('JSON 损坏时按 0 计而不是抛异常', () {
      final summary = summarizeMessageRefs('{"不是合法的消息数组": ');
      expect(summary.messageCount, 0);
      expect(summary.imageRefCount, 0);
      expect(summarizeMessageRefs(null).messageCount, 0);
    });
  });

  group('formatChatStorageBytes 体积展示', () {
    test('按量级切换单位', () {
      expect(formatChatStorageBytes(0), '0 B');
      expect(formatChatStorageBytes(512), '512 B');
      expect(formatChatStorageBytes(2048), '2.0 KB');
      expect(formatChatStorageBytes(64 * 1024), '64 KB');
      expect(formatChatStorageBytes(3 * 1024 * 1024), '3.0 MB');
    });
  });
}
