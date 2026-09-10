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
  });
}
