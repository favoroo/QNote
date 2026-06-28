import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/models/folder.dart';

final folderRepositoryProvider = Provider<FolderRepository>((ref) {
  return FolderRepository();
});

final folderListProvider =
    AsyncNotifierProvider<FolderListNotifier, List<Folder>>(() {
  return FolderListNotifier();
});

class FolderListNotifier extends AsyncNotifier<List<Folder>> {
  @override
  Future<List<Folder>> build() async {
    final repo = ref.read(folderRepositoryProvider);
    return repo.getByType('note');
  }

  Future<void> refresh() async {
    final repo = ref.read(folderRepositoryProvider);
    state = AsyncData(await repo.getByType('note'));
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
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((f) => f.id == folder.id ? folder : f)
          .toList(),
    );
  }

  Future<void> deleteFolder(String id) async {
    final repo = ref.read(folderRepositoryProvider);
    await repo.delete(id);
    // 内存移除当前文件夹；调用方若需级联删除子文件夹应在外部处理
    state = AsyncData(
      (state.valueOrNull ?? []).where((f) => f.id != id).toList(),
    );
  }

  Future<void> toggleExpanded(String id, bool isExpanded) async {
    final repo = ref.read(folderRepositoryProvider);
    final folder = await repo.getById(id);
    if (folder != null) {
      final updated = folder.copyWith(isExpanded: isExpanded);
      await repo.update(updated);
      // 内存替换
      state = AsyncData(
        (state.valueOrNull ?? [])
            .map((f) => f.id == id ? updated : f)
            .toList(),
      );
    }
  }

  Future<void> moveFolderToParent(String folderId, String? parentId) async {
    final repo = ref.read(folderRepositoryProvider);
    final folder = await repo.getById(folderId);
    if (folder != null) {
      final updated = folder.copyWith(
        parentId: parentId,
        clearParentId: parentId == null,
      );
      await repo.update(updated);
      // 内存替换
      state = AsyncData(
        (state.valueOrNull ?? [])
            .map((f) => f.id == folderId ? updated : f)
            .toList(),
      );
    }
  }

  Future<void> reorderFolders(List<Folder> reordered) async {
    final repo = ref.read(folderRepositoryProvider);
    final currentList = state.valueOrNull ?? [];
    final updatedList = currentList.map((folder) {
      return reordered.firstWhere((f) => f.id == folder.id, orElse: () => folder);
    }).toList();

    state = AsyncData(updatedList);
    await repo.batchUpdate(reordered);
  }
}
