import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/todo.dart';

void main() {
  group('Todo toMap/fromMap roundtrip', () {
    test('should survive roundtrip with default values', () {
      final now = DateTime(2026, 6, 14, 10, 30);
      final todo = Todo(
        id: 'todo-1',
        title: '测试待办',
        createdAt: now,
        updatedAt: now,
      );

      final map = todo.toMap();
      final restored = Todo.fromMap(map);

      expect(restored.id, todo.id);
      expect(restored.title, todo.title);
      expect(restored.description, '');
      expect(restored.isCompleted, false);
      expect(restored.priority, 'normal');
      expect(restored.tags, '');
      expect(restored.isLongTerm, false);
      expect(restored.sortOrder, 0);
      expect(restored.isDeleted, false);
    });

    test('should survive roundtrip with full values', () {
      final now = DateTime(2026, 6, 14, 10, 30);
      final todo = Todo(
        id: 'todo-2',
        title: '完整待办',
        description: '详细描述',
        isCompleted: true,
        priority: 'important',
        dueDate: DateTime(2026, 6, 20),
        tags: '工作,紧急',
        folderId: 'folder-1',
        isLongTerm: true,
        reminderTime: '09:00',
        deadline: DateTime(2026, 6, 25),
        sortOrder: 5,
        createdAt: now,
        updatedAt: now,
        isDeleted: true,
      );

      final map = todo.toMap();
      final restored = Todo.fromMap(map);

      expect(restored.id, todo.id);
      expect(restored.title, todo.title);
      expect(restored.description, todo.description);
      expect(restored.isCompleted, true);
      expect(restored.priority, 'important');
      expect(restored.dueDate, todo.dueDate);
      expect(restored.tags, todo.tags);
      expect(restored.folderId, todo.folderId);
      expect(restored.isLongTerm, true);
      expect(restored.reminderTime, '09:00');
      expect(restored.deadline, todo.deadline);
      expect(restored.sortOrder, 5);
      expect(restored.isDeleted, true);
    });
  });

  group('Todo copyWith', () {
    test('should return new instance with changed fields', () {
      final now = DateTime(2026, 6, 14);
      final todo = Todo(
        id: '1',
        title: '原任务',
        createdAt: now,
        updatedAt: now,
      );

      final copied = todo.copyWith(title: '新任务', isCompleted: true);
      expect(copied.title, '新任务');
      expect(copied.isCompleted, true);
      expect(copied.id, todo.id);
    });

    test('should not mutate original', () {
      final now = DateTime(2026, 6, 14);
      final todo = Todo(
        id: '1',
        title: '原任务',
        createdAt: now,
        updatedAt: now,
      );

      todo.copyWith(title: '新任务');
      expect(todo.title, '原任务');
    });

    test('clearFolderId should set folderId to null', () {
      final now = DateTime(2026, 6, 14);
      final todo = Todo(
        id: '1',
        title: 'Test',
        folderId: 'folder-1',
        createdAt: now,
        updatedAt: now,
      );

      final copied = todo.copyWith(clearFolderId: true);
      expect(copied.folderId, isNull);
    });

    test('clearReminderTime should set reminderTime to null', () {
      final now = DateTime(2026, 6, 14);
      final todo = Todo(
        id: '1',
        title: 'Test',
        reminderTime: '09:00',
        createdAt: now,
        updatedAt: now,
      );

      final copied = todo.copyWith(clearReminderTime: true);
      expect(copied.reminderTime, isNull);
    });
  });
}

