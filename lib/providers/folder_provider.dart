import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/refresh/refresh_failure_notice.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/models/folder.dart';

final folderRepositoryProvider = Provider<FolderRepository>((ref) {
  return FolderRepository();
});

final folderListProvider = AsyncNotifierProvider<FolderListNotifier, List<Folder>>(() {
  return FolderListNotifier();
});

class FolderListNotifier extends AsyncNotifier<List<Folder>> {
  @override
  Future<List<Folder>> build() async {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path.startsWith('/folders') || event.path.startsWith('/notes/')) {
        refresh();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });

    // 笔记页可见的文件夹：普通笔记文件夹 + 日记体系（根目录与月份子文件夹）
    final repo = ref.read(folderRepositoryProvider);
    await JournalService.instance.ensureRootFolder();
    // 顺带清理历史残留的空日记与空月份文件夹（会话级仅执行一次）
    await JournalService.instance.cleanupEmptyJournalsIfNeeded();
    return repo.getByTypes(['note', JournalService.rootFolderType, JournalService.monthFolderType]);
  }

  Future<void> refresh() async {
    final repo = ref.read(folderRepositoryProvider);
    try {
      await JournalService.instance.ensureRootFolder();
      await JournalService.instance.cleanupEmptyJournalsIfNeeded();
      state = AsyncData(await repo.getByTypes(['note', JournalService.rootFolderType, JournalService.monthFolderType]));
    } catch (e, st) {
      RefreshFailureNotice.report(
        source: '文件夹',
        error: e,
        stackTrace: st,
        retry: () {
          refresh();
        },
      );
    }
  }

  Future<Folder> addFolder(String name, [String? parentId]) async {
    final repo = ref.read(folderRepositoryProvider);
    final now = DateTime.now();
    final folder = Folder(
      id: const Uuid().v4(),
      name: name,
      parentId: parentId,
      type: 'note',
      createdAt: now,
      updatedAt: now,
    );
    await repo.insert(folder);
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), folder]);
    return folder;
  }

  Future<void> updateFolder(Folder folder) async {
    final repo = ref.read(folderRepositoryProvider);
    await repo.update(folder);
    // 内存替换目标项
    state = AsyncData((state.valueOrNull ?? []).map((f) => f.id == folder.id ? folder : f).toList());
  }

  Future<void> deleteFolder(String id) async {
    final repo = ref.read(folderRepositoryProvider);
    await repo.delete(id);
    // 内存移除当前文件夹；调用方若需级联删除子文件夹应在外部处理
    state = AsyncData((state.valueOrNull ?? []).where((f) => f.id != id).toList());
  }

  Future<void> toggleExpanded(String id, bool isExpanded) async {
    final repo = ref.read(folderRepositoryProvider);
    final folder = await repo.getById(id);
    if (folder != null) {
      final updated = folder.copyWith(isExpanded: isExpanded);
      await repo.update(updated);
      // 内存替换
      state = AsyncData((state.valueOrNull ?? []).map((f) => f.id == id ? updated : f).toList());
    }
  }

  /// 批量保存重排结果。
  ///
  /// 调用方必须先在传入的 Folder 上设置好 `parentId` / `sortOrder`。
  /// 先落库成功再更新内存：写失败时界面不会先动、库却还是旧值。
  Future<void> reorderFolders(List<Folder> reordered) async {
    if (reordered.isEmpty) return;

    final repo = ref.read(folderRepositoryProvider);
    await repo.batchUpdate(reordered);

    final currentList = state.valueOrNull;
    if (currentList == null) return;
    final replacements = <String, Folder>{for (final folder in reordered) folder.id: folder};
    state = AsyncData([for (final folder in currentList) replacements[folder.id] ?? folder]);
  }
}
