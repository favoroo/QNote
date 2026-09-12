import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';

void main() {
  group('WorkspaceUndoEntry 序列化测试', () {
    test('toMap/fromMap 应保留 path、existedBefore 与 beforeContent', () {
      const entry = WorkspaceUndoEntry(
        path: '/todos/工作/abc-123.md',
        existedBefore: true,
        beforeContent: '---\nid: "abc-123"\n---\n原始内容',
      );

      final restored = WorkspaceUndoEntry.fromMap(entry.toMap());
      expect(restored.path, entry.path);
      expect(restored.existedBefore, isTrue);
      expect(restored.beforeContent, entry.beforeContent);
    });

    test('existedBefore 为 false 时 beforeContent 缺省', () {
      const entry = WorkspaceUndoEntry(path: '/notes/新笔记.md', existedBefore: false);

      final map = entry.toMap();
      expect(map.containsKey('before_content'), isFalse);

      final restored = WorkspaceUndoEntry.fromMap(map);
      expect(restored.existedBefore, isFalse);
      expect(restored.beforeContent, isNull);
    });

    test('encodeList/decodeList 列表往返一致', () {
      final entries = [
        const WorkspaceUndoEntry(
          path: '/timeline/2026-09-12.md',
          existedBefore: true,
          beforeContent: '## [09:00] 晨跑 <!-- id: r1 -->',
        ),
        const WorkspaceUndoEntry(path: '/journal/2026-09-12.md', existedBefore: false),
      ];

      final raw = WorkspaceUndoEntry.encodeList(entries);
      final decoded = WorkspaceUndoEntry.decodeList(raw);
      expect(decoded.length, 2);
      expect(decoded[0].path, '/timeline/2026-09-12.md');
      expect(decoded[0].beforeContent, contains('晨跑'));
      expect(decoded[1].existedBefore, isFalse);
      // 编码结果必须是合法 JSON 字符串（存入 ChatMessage.undoLog）
      expect(() => jsonDecode(raw), returnsNormally);
    });

    test('decodeList 对 null/空串/非法 JSON 容错返回空列表', () {
      expect(WorkspaceUndoEntry.decodeList(null), isEmpty);
      expect(WorkspaceUndoEntry.decodeList(''), isEmpty);
      expect(WorkspaceUndoEntry.decodeList('not-json'), isEmpty);
      expect(WorkspaceUndoEntry.decodeList('{"a": 1}'), isEmpty);
    });

    test('decodeList 对缺失字段容错', () {
      final decoded = WorkspaceUndoEntry.decodeList('[{"path": "/settings/profile.json"}]');
      expect(decoded.length, 1);
      expect(decoded.first.path, '/settings/profile.json');
      expect(decoded.first.existedBefore, isFalse);
      expect(decoded.first.beforeContent, isNull);
    });
  });
}
