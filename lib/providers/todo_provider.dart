import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';
import 'package:qnote_flutter/core/utils/widget_utils.dart';

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
  final completed = await repo.getCompleted();
  return completed.where((t) => t.title.trim().isNotEmpty).toList();
});

final upcomingRemindersProvider = FutureProvider<List<Todo>>((ref) async {
  final repo = ref.read(todoRepositoryProvider);
  return repo.getUpcomingReminders();
});

class TodoListNotifier extends AsyncNotifier<List<Todo>> {
  @override
  Future<List<Todo>> build() async {
    final repo = ref.read(todoRepositoryProvider);
    // 启动初始化时自动清理存量空待办脏数据，并自愈修复未关联分类的孤儿待办
    await repo.cleanEmptyTodos();
    await repo.healNullFolderIds();
    return repo.getAll();
  }

  Future<void> refresh() async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.cleanEmptyTodos();
    await repo.healNullFolderIds();
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
    String repeatRule = 'none',
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
      repeatRule: repeatRule,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
      updatedAt: now,
    );
    await repo.insert(todo);
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), todo]);
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
    return todo;
  }

  Future<void> updateTodo(Todo todo) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.update(todo);
    await NotificationService.instance.scheduleTodoReminder(todo);
    // 内存替换目标项
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((t) => t.id == todo.id ? todo : t)
          .toList(),
    );
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> deleteTodo(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.softDelete(id);
    await NotificationService.instance.cancelNotification(id.hashCode);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((t) => t.id != id).toList(),
    );
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  /// 根据周期规则推算下一个周期的日期
  static DateTime calculateNextRecurringDate(DateTime baseDate, String repeatRule) {
    switch (repeatRule) {
      case 'daily':
        return baseDate.add(const Duration(days: 1));
      case 'workday':
        var next = baseDate.add(const Duration(days: 1));
        while (next.weekday == DateTime.saturday || next.weekday == DateTime.sunday) {
          next = next.add(const Duration(days: 1));
        }
        return next;
      case 'weekly':
        return baseDate.add(const Duration(days: 7));
      case 'monthly':
        final newYear = baseDate.month == 12 ? baseDate.year + 1 : baseDate.year;
        final newMonth = baseDate.month == 12 ? 1 : baseDate.month + 1;
        final daysInNextMonth = DateTime(newYear, newMonth + 1, 0).day;
        final newDay = baseDate.day > daysInNextMonth ? daysInNextMonth : baseDate.day;
        return DateTime(newYear, newMonth, newDay, baseDate.hour, baseDate.minute, baseDate.second);
      case 'yearly':
        final newYear = baseDate.year + 1;
        final daysInMonth = DateTime(newYear, baseDate.month + 1, 0).day;
        final newDay = baseDate.day > daysInMonth ? daysInMonth : baseDate.day;
        return DateTime(newYear, baseDate.month, newDay, baseDate.hour, baseDate.minute, baseDate.second);
      default:
        return baseDate;
    }
  }

  /// 推算下一次提醒时间字符串（格式形如 "MM-dd HH:mm"）
  static String? computeNextReminderTime(String currentReminderStr, String repeatRule) {
    try {
      final parts = currentReminderStr.split(' ');
      final dateParts = parts[0].split('-');
      final timeParts = parts[1].split(':');
      final now = DateTime.now();
      final base = DateTime(
        now.year,
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
      );
      var next = calculateNextRecurringDate(base, repeatRule);
      while (next.isBefore(now)) {
        next = calculateNextRecurringDate(next, repeatRule);
      }
      final mm = next.month.toString().padLeft(2, '0');
      final dd = next.day.toString().padLeft(2, '0');
      final hh = next.hour.toString().padLeft(2, '0');
      final min = next.minute.toString().padLeft(2, '0');
      return '$mm-$dd $hh:$min';
    } catch (_) {
      return null;
    }
  }

  Future<void> toggleComplete(String id, bool isCompleted) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.toggleComplete(id, isCompleted);
    final completedTodo = await repo.getById(id);
    if (completedTodo != null) {
      await NotificationService.instance.scheduleTodoReminder(completedTodo);
    }

    Todo? nextRecurringTodo;
    // 依据用户选择：重复任务完成时，归档当期并自动生成下一周期的新待办
    if (isCompleted && completedTodo != null && completedTodo.isRecurring) {
      final now = DateTime.now();
      DateTime? nextDueDate;
      if (completedTodo.dueDate != null) {
        nextDueDate = calculateNextRecurringDate(completedTodo.dueDate!, completedTodo.repeatRule);
      }
      String? nextReminder;
      if (completedTodo.reminderTime != null) {
        nextReminder = computeNextReminderTime(completedTodo.reminderTime!, completedTodo.repeatRule);
      }

      nextRecurringTodo = Todo(
        id: const Uuid().v4(),
        title: completedTodo.title,
        description: completedTodo.description,
        priority: completedTodo.priority,
        dueDate: nextDueDate,
        tags: completedTodo.tags,
        folderId: completedTodo.folderId,
        isLongTerm: completedTodo.isLongTerm,
        reminderTime: nextReminder,
        repeatRule: completedTodo.repeatRule,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
        updatedAt: now,
      );
      await repo.insert(nextRecurringTodo);
      if (nextReminder != null) {
        await NotificationService.instance.scheduleTodoReminder(nextRecurringTodo);
      }
    }

    // 内存替换与增量同步
    final currentList = state.valueOrNull ?? [];
    final updatedList = currentList
        .map((t) => t.id == id ? (completedTodo ?? t.copyWith(isCompleted: isCompleted)) : t)
        .toList();
    if (nextRecurringTodo != null) {
      updatedList.add(nextRecurringTodo);
    }

    state = AsyncData(updatedList);
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  /// 更新待办重复规则
  Future<void> setRepeatRule(String id, String repeatRule) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final updated = todo.copyWith(repeatRule: repeatRule);
    await repo.update(updated);
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((t) => t.id == id ? updated : t)
          .toList(),
    );
    ref.invalidate(completedTodoListProvider);
    WidgetUtils.updateHomeWidgets();
  }

  /// 移动待办至指定分类
  Future<void> moveToFolder(String id, String folderId) async {
    final repo = ref.read(todoRepositoryProvider);
    final updated = await repo.moveToFolder(id, folderId);
    if (updated != null) {
      state = AsyncData(
        (state.valueOrNull ?? [])
            .map((t) => t.id == id ? updated : t)
            .toList(),
      );
    }
    ref.invalidate(completedTodoListProvider);
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> setReminder(String id, String reminderTime) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final updated = todo.copyWith(reminderTime: reminderTime);
    await repo.update(updated);
    await NotificationService.instance.scheduleTodoReminder(updated);
    // 内存替换
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((t) => t.id == id ? updated : t)
          .toList(),
    );
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
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
    // 内存替换
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((t) => t.id == id ? updated : t)
          .toList(),
    );
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> moveToLongTerm(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.moveToLongTerm(id);
    // 重新查询单条并以内存增量更新，确保长期标签页能正确读取
    final todo = await repo.getById(id);
    if (todo != null) {
      final exists = (state.valueOrNull ?? []).any((t) => t.id == id);
      if (exists) {
        state = AsyncData(
          (state.valueOrNull ?? [])
              .map((t) => t.id == id ? todo : t)
              .toList(),
        );
      } else {
        state = AsyncData([...(state.valueOrNull ?? []), todo]);
      }
    }
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> moveToToday(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.moveToToday(id);
    // 重新查询单条并以内存增量更新
    final todo = await repo.getById(id);
    if (todo != null) {
      final exists = (state.valueOrNull ?? []).any((t) => t.id == id);
      if (exists) {
        state = AsyncData(
          (state.valueOrNull ?? [])
              .map((t) => t.id == id ? todo : t)
              .toList(),
        );
      } else {
        state = AsyncData([...(state.valueOrNull ?? []), todo]);
      }
    }
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> togglePriority(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final newPriority = todo.priority == 'important' ? 'normal' : 'important';
    final updated = todo.copyWith(priority: newPriority);
    await repo.update(updated);
    // 内存替换，priority 变化不影响 completed/reminders 派生 Provider
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((t) => t.id == id ? updated : t)
          .toList(),
    );
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> restoreTodo(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    final todo = await repo.getById(id);
    if (todo == null) return;
    final updated = todo.copyWith(isCompleted: false);
    await repo.update(updated);
    await NotificationService.instance.scheduleTodoReminder(updated);
    // 内存替换
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((t) => t.id == id ? updated : t)
          .toList(),
    );
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
  }

  Future<void> permanentDelete(String id) async {
    final repo = ref.read(todoRepositoryProvider);
    await repo.hardDelete(id);
    await NotificationService.instance.cancelNotification(id.hashCode);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((t) => t.id != id).toList(),
    );
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    WidgetUtils.updateHomeWidgets();
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
    WidgetUtils.updateHomeWidgets();
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
