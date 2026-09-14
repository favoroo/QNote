import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';

final todoFolderRepositoryProvider = Provider<FolderRepository>((ref) {
  return FolderRepository();
});

/// 当前选中的待办分类 ID
final selectedTodoFolderIdProvider = StateProvider<String?>((ref) => null);

/// 待办分类列表管理
final todoFolderListProvider =
    AsyncNotifierProvider<TodoFolderListNotifier, List<Folder>>(() {
  return TodoFolderListNotifier();
});

class TodoFolderListNotifier extends AsyncNotifier<List<Folder>> {
  @override
  Future<List<Folder>> build() async {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path.startsWith('/folders') || event.path.startsWith('/todos/')) {
        refresh();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });

    final repo = ref.read(todoFolderRepositoryProvider);
    var folders = await repo.getByType('todo');

    // 兜底保障：若没有任何待办分类，初始化系统默认的“今日”和“长期”
    if (folders.isEmpty) {
      final now = DateTime.now();
      final todayFolder = Folder(
        id: 'todo_default_today',
        name: '今日',
        type: 'todo',
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      );
      final longtermFolder = Folder(
        id: 'todo_default_longterm',
        name: '长期',
        type: 'todo',
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      );
      await repo.insert(todayFolder);
      await repo.insert(longtermFolder);
      folders = [todayFolder, longtermFolder];
    }

    // 若当前未选中任何分类，默认选中第一个分类
    final selectedId = ref.read(selectedTodoFolderIdProvider);
    if (selectedId == null || !folders.any((f) => f.id == selectedId)) {
      Future.microtask(() {
        ref.read(selectedTodoFolderIdProvider.notifier).state = folders.first.id;
      });
    }

    return folders;
  }

  /// 刷新待办分类
  Future<void> refresh() async {
    final repo = ref.read(todoFolderRepositoryProvider);
    final folders = await repo.getByType('todo');
    state = AsyncData(folders);
  }

  /// 新增待办分类
  Future<Folder> addFolder(String name) async {
    final repo = ref.read(todoFolderRepositoryProvider);
    final currentFolders = state.valueOrNull ?? [];
    final now = DateTime.now();
    final folder = Folder(
      id: const Uuid().v4(),
      name: name.trim(),
      type: 'todo',
      sortOrder: currentFolders.length,
      createdAt: now,
      updatedAt: now,
    );
    await repo.insert(folder);
    final updated = [...currentFolders, folder];
    state = AsyncData(updated);

    // 自动选中新创建的分类
    ref.read(selectedTodoFolderIdProvider.notifier).state = folder.id;
    return folder;
  }

  /// 重命名待办分类
  Future<void> updateFolder(String id, String newName) async {
    final repo = ref.read(todoFolderRepositoryProvider);
    final currentFolders = state.valueOrNull ?? [];
    final target = currentFolders.where((f) => f.id == id).firstOrNull;
    if (target == null) return;

    final updatedFolder = target.copyWith(
      name: newName.trim(),
      updatedAt: DateTime.now(),
    );
    await repo.update(updatedFolder);
    state = AsyncData(
      currentFolders.map((f) => f.id == id ? updatedFolder : f).toList(),
    );
  }

  /// 删除待办分类（至少保留一个分类，同时软删除该分类下的所有待办）
  /// 返回：true 表示删除成功，false 表示因“至少保留一个分类”而拒绝删除
  Future<bool> deleteFolder(String id) async {
    final currentFolders = state.valueOrNull ?? [];
    if (currentFolders.length <= 1) {
      // 强约束：至少保留一个分类
      return false;
    }

    final repo = ref.read(todoFolderRepositoryProvider);
    final todoRepo = ref.read(todoRepositoryProvider);

    // 1. 级联软删除该分类下的所有待办
    await todoRepo.deleteByFolder(id);

    // 2. 删除分类记录
    await repo.delete(id);

    // 3. 更新内存列表
    final remainingFolders = currentFolders.where((f) => f.id != id).toList();
    state = AsyncData(remainingFolders);

    // 4. 若当前选中的正好是被删除分类，切到剩余第一个
    final currentSelectedId = ref.read(selectedTodoFolderIdProvider);
    if (currentSelectedId == id) {
      ref.read(selectedTodoFolderIdProvider.notifier).state =
          remainingFolders.isNotEmpty ? remainingFolders.first.id : null;
    }

    // 5. 刷新待办列表状态
    ref.read(todoListProvider.notifier).refresh();
    return true;
  }

  /// 调整分类顺序
  Future<void> reorderFolders(List<Folder> newOrder) async {
    final repo = ref.read(todoFolderRepositoryProvider);
    for (var i = 0; i < newOrder.length; i++) {
      final folder = newOrder[i];
      if (folder.sortOrder != i) {
        await repo.updateSortOrder(folder.id, i);
      }
    }
    state = AsyncData(newOrder);
  }
}
