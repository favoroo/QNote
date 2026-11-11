import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/refresh/refresh_failure_notice.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/models/note.dart';

final noteRepositoryProvider = Provider<NoteRepository>((ref) {
  return NoteRepository();
});

final noteListProvider = AsyncNotifierProvider<NoteListNotifier, List<Note>>(() {
  return NoteListNotifier();
});

class NoteListNotifier extends AsyncNotifier<List<Note>> {
  @override
  Future<List<Note>> build() async {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path.startsWith('/notes/')) {
        refresh();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });

    final repo = ref.read(noteRepositoryProvider);
    return repo.getAll();
  }

  Future<void> refresh() async {
    final repo = ref.read(noteRepositoryProvider);
    try {
      state = AsyncData(await repo.getAll());
    } catch (e, st) {
      RefreshFailureNotice.report(
        source: '笔记',
        error: e,
        stackTrace: st,
        retry: () {
          refresh();
        },
      );
    }
  }

  Future<Note> addNote({required String title, String content = '', String? folderId, String tags = ''}) async {
    final repo = ref.read(noteRepositoryProvider);
    final now = DateTime.now();
    final note = Note(
      id: const Uuid().v4(),
      title: title,
      content: content,
      folderId: folderId,
      tags: tags,
      createdAt: now,
      updatedAt: now,
    );
    await repo.insert(note);
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), note]);
    return note;
  }

  Future<void> updateNote(Note note) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.update(note);
    // 内存替换目标项
    state = AsyncData((state.valueOrNull ?? []).map((n) => n.id == note.id ? note : n).toList());
  }

  Future<void> deleteNote(String id) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.softDelete(id);
    // 内存移除
    state = AsyncData((state.valueOrNull ?? []).where((n) => n.id != id).toList());
  }

  Future<void> togglePin(String id, bool isPinned) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.togglePin(id, isPinned);
    // 内存替换：仅更新 isPinned 字段
    state = AsyncData((state.valueOrNull ?? []).map((n) => n.id == id ? n.copyWith(isPinned: isPinned) : n).toList());
  }

  Future<void> searchNotes(String keyword) async {
    final repo = ref.read(noteRepositoryProvider);
    if (keyword.isEmpty) {
      await refresh();
      return;
    }
    state = AsyncData(await repo.search(keyword));
  }

  /// 批量保存重排结果。
  ///
  /// 调用方必须先在传入的 Note 上设置好 `folderId` / `sortOrder`。
  /// 先落库成功再更新内存：写失败时界面不会先动、库却还是旧值。
  Future<void> reorderNotes(List<Note> reordered) async {
    if (reordered.isEmpty) return;

    final repo = ref.read(noteRepositoryProvider);
    await repo.batchUpdate(reordered);

    final currentList = state.valueOrNull;
    if (currentList == null) return;
    final replacements = <String, Note>{for (final note in reordered) note.id: note};
    state = AsyncData([for (final note in currentList) replacements[note.id] ?? note]);
  }
}

final noteDetailProvider = FutureProvider.family<Note?, String>((ref, id) async {
  final repo = ref.read(noteRepositoryProvider);
  return repo.getById(id);
});
