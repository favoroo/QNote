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
    await refresh();
    return folder;
  }

  Future<void> updateFolder(Folder folder) async {
    final repo = ref.read(folderRepositoryProvider);
    await repo.update(folder);
    await refresh();
  }

  Future<void> deleteFolder(String id) async {
    final repo = ref.read(folderRepositoryProvider);
    await repo.delete(id);
    await refresh();
  }

  Future<void> toggleExpanded(String id, bool isExpanded) async {
    final repo = ref.read(folderRepositoryProvider);
    final folder = await repo.getById(id);
    if (folder != null) {
      await repo.update(folder.copyWith(isExpanded: isExpanded));
      await refresh();
    }
  }

  Future<void> moveFolderToParent(String folderId, String? parentId) async {
    final repo = ref.read(folderRepositoryProvider);
    final folder = await repo.getById(folderId);
    if (folder != null) {
      await repo.update(folder.copyWith(
        parentId: parentId,
        clearParentId: parentId == null,
      ));
      await refresh();
    }
  }
}
