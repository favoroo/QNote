import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  group('ChatMessage & ChatSession model tests', () {
    test('ChatMessage toMap and fromMap should preserve images', () {
      final now = DateTime.now();
      final msg = ChatMessage(
        role: 'user',
        content: '分析这几张图片',
        timestamp: now,
        images: ['/path/to/img1.jpg', '/path/to/img2.png'],
      );

      final map = msg.toMap();
      expect(map['role'], 'user');
      expect(map['content'], '分析这几张图片');
      expect(map['images'], ['/path/to/img1.jpg', '/path/to/img2.png']);

      final restored = ChatMessage.fromMap(map);
      expect(restored.role, 'user');
      expect(restored.content, '分析这几张图片');
      expect(restored.images, ['/path/to/img1.jpg', '/path/to/img2.png']);
      expect(restored.timestamp?.toIso8601String(), now.toIso8601String());
    });

    test('ChatMessage backward compatibility without images', () {
      final legacyMap = {
        'role': 'assistant',
        'content': '你好，有什么可以帮你？',
        'timestamp': DateTime.now().toIso8601String(),
      };

      final msg = ChatMessage.fromMap(legacyMap);
      expect(msg.role, 'assistant');
      expect(msg.content, '你好，有什么可以帮你？');
      expect(msg.images, isNull);
    });

    test('ChatSession toMap and fromMap with images in messages', () {
      final now = DateTime.now();
      final session = ChatSession(
        id: 'sess-1',
        title: '图片分析测试',
        messages: [
          ChatMessage(
            role: 'user',
            content: '看图',
            images: ['/image1.jpg'],
            timestamp: now,
          ),
          ChatMessage(
            role: 'assistant',
            content: '这是一张风景照',
            timestamp: now,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      );

      final map = session.toMap();
      final restored = ChatSession.fromMap(map);

      expect(restored.id, 'sess-1');
      expect(restored.messages.length, 2);
      expect(restored.messages[0].images, ['/image1.jpg']);
      expect(restored.messages[1].images, isNull);
    });

    test('ChatMessage toMap/fromMap 应保留 undoLog', () {
      const undoLog = '[{"path":"/todos/工作/abc.md","existed_before":true,"before_content":"原始"}]';
      final msg = ChatMessage(
        role: 'user',
        content: '帮我加个待办',
        undoLog: undoLog,
      );

      final restored = ChatMessage.fromMap(msg.toMap());
      expect(restored.undoLog, undoLog);

      // copyWith 支持（与其他可空字段同语义：传 null 保留原值）
      const newLog = '[{"path":"/notes/b.md","existed_before":false}]';
      expect(msg.copyWith(undoLog: newLog).undoLog, newLog);
      expect(msg.copyWith().undoLog, undoLog);
    });

    test('ChatMessage 旧数据无 undo_log 字段时向后兼容', () {
      final msg = ChatMessage.fromMap({
        'role': 'user',
        'content': '历史消息',
      });
      expect(msg.undoLog, isNull);
      // toMap 不应写出空的 undo_log 键
      expect(msg.toMap().containsKey('undo_log'), isFalse);
    });
  });
}
