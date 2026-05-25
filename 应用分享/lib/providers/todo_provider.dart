import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';

final todoRepositoryProvider = Provider<TodoRepository>((ref) {
  return TodoRepository();
});

final isLongTermFilterProvider = StateProvider<bool>((ref) => false);

final todoListProvider = AsyncNotifierProvider<TodoListNotifier, List<Todo>>(
  () {
    return TodoListNotifier();
  },
);

final todoFilterProvider = StateProvider<TodoFilter>((ref) => TodoFilter.all);

final filteredTodoListProvider =
    AsyncNotifierProvider<FilteredTodoListNotifier, List<Todo>>(() {
      return FilteredTodoListNotifier();
    });

final completedTodoListProvider = FutureProvider<List<Todo>>((ref) async {
  final repo = ref.read(todoRepositoryProvider);
  return repo.getCompleted();
});

final upcomingRemindersProvider = FutureProvider<List<Todo>>((ref) async {
  final repo = ref.read(todoRepositoryProvider);
  return repo.getUpcomingReminders();
});

class TodoListNotifier extends AsyncNotifier<List<Todo>> {
  @override
  Future<List<Todo>> build() async {
    final repo = ref.read(todoRepositoryProvider);
    return repo.getAll();
  }

  Future<void> refresh() async {
    final repo = ref.read(todoRepositoryProvider);
    state = AsyncData(await repo.getAll());
    // Invalidate other providers to force them to reload from the database
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
  }

  Future<void> loadByIsLongTerm(bool isLongTerm) async {
    final repo = ref.read(todoRepositoryProvider);
    state = AsyncData(await repo.getByIsLongTerm(isLongTerm));
  }

  Future<void> loadCompletedByIsLongTerm(bool isLongTerm) async {
    final repo = ref.read(todoRepositoryProvider);
    state = AsyncData(await repo.getCompletedByIsLongTerm(isLongTerm));
  }

  Future<Todo> addTodo({
    required String title,
    String description = '',
    String priority = 'normal',
    DateTime? dueDate,
    String tags = '',
    String? folderId,
    bool isLongTerm = false,
  }) async {
    final repo = ref.read(todoRepositoryProvider);
    final now = DateTime.now();
    final todo = Todo(
      id: const Uuid().v4(),
      title: title,
      description: description,
      priority: priority,
      dueDate: dueDate,
      tags: tags,
      folderId: folderId,
      isLongTerm: isLongTerm,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
      updatedAt: now,
    );
    await repo.insert(todo);
    await refresh();
    return todo;
  }

  Future<void> updateTodo(Todo todo) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.update(todo);
    await NotificationService.instance.scheduleTodoReminder(todo);
    await refresh();
  }

  Future<void> deleteTodo(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.softDelete(id);
    await NotificationService.instance.cancelNotification(id.hashCode);
    await refresh();
  }

  Future<void> toggleComplete(String id, bool isCompleted) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.toggleComplete(id, isCompleted);
    final todo = await repo.getById(id);
    if (todo != null) {
      await NotificationService.instance.scheduleTodoReminder(todo);
    }
    await refresh();
  }

  Future<void> setReminder(String id, String reminderTime) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final updated = todo.copyWith(reminderTime: reminderTime);
    await repo.update(updated);
    await NotificationService.instance.scheduleTodoReminder(updated);
    await refresh();
  }

  Future<void> clearReminder(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final updated = todo.copyWith(
      reminderTime: null,
      clearReminderTime: true,
    );
    await repo.update(updated);
    await NotificationService.instance.cancelNotification(id.hashCode);
    await refresh();
  }

  Future<void> moveToLongTerm(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.moveToLongTerm(id);
    await refresh();
  }

  Future<void> moveToToday(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.moveToToday(id);
    await refresh();
  }

  Future<void> togglePriority(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final newPriority = todo.priority == 'important' ? 'normal' : 'important';
    final updated = todo.copyWith(priority: newPriority);
    await repo.update(updated);
    await refresh();
  }

  Future<void> restoreTodo(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final updated = todo.copyWith(isCompleted: false);
    await repo.update(updated);
    await NotificationService.instance.scheduleTodoReminder(updated);
    await refresh();
  }

  Future<void> permanentDelete(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.hardDelete(id);
    await NotificationService.instance.cancelNotification(id.hashCode);
    await refresh();
  }

  Future<void> searchTodos(String keyword) async {
    final repo = ref.read(todoRepositoryProvider);
    if (keyword.isEmpty) {
      await refresh();
      return;
    }
    state = AsyncData(await repo.search(keyword));
  }

  Future<void> reorderTodos(List<Todo> reordered) async {
    final repo = ref.read(todoRepositoryProvider);
    final now = DateTime.now();
    final updated = <Todo>[];
    for (int i = 0; i < reordered.length; i++) {
      updated.add(reordered[i].copyWith(
        sortOrder: i,
        updatedAt: now,
      ));
    }
    // Update the state immediately in memory to prevent flashing/lag in the UI
    state = AsyncData(updated);
    
    // Save to database in the background
    await repo.batchUpdate(updated);
    
    // Invalidate other related providers
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
  }
}

class FilteredTodoListNotifier extends AsyncNotifier<List<Todo>> {
  @override
  Future<List<Todo>> build() async {
    final filter = ref.watch(todoFilterProvider);
    final todos = ref.watch(todoListProvider).valueOrNull ?? [];
    switch (filter) {
      case TodoFilter.all:
        return todos;
      case TodoFilter.pending:
        return todos.where((t) => !t.isCompleted).toList();
      case TodoFilter.completed:
        return todos.where((t) => t.isCompleted).toList();
    }
  }
}

enum TodoFilter { all, pending, completed }
