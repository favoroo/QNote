import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
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
    state = AsyncData(await repo.getAll());
  }

  Future<Note> addNote({
    required String title,
    String content = '',
    String? folderId,
    String tags = '',
  }) async {
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
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((n) => n.id == note.id ? note : n)
          .toList(),
    );
  }

  Future<void> deleteNote(String id) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.softDelete(id);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((n) => n.id != id).toList(),
    );
  }

  Future<void> togglePin(String id, bool isPinned) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.togglePin(id, isPinned);
    // 内存替换：仅更新 isPinned 字段
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((n) => n.id == id ? n.copyWith(isPinned: isPinned) : n)
          .toList(),
    );
  }

  Future<void> searchNotes(String keyword) async {
    final repo = ref.read(noteRepositoryProvider);
    if (keyword.isEmpty) {
      await refresh();
      return;
    }
    state = AsyncData(await repo.search(keyword));
  }

  Future<void> moveNoteToFolder(String noteId, String? folderId) async {
    final repo = ref.read(noteRepositoryProvider);
    final note = await repo.getById(noteId);
    if (note != null) {
      final updated = note.copyWith(
        folderId: folderId,
        clearFolderId: folderId == null,
      );
      await repo.update(updated);
      // 内存替换
      state = AsyncData(
        (state.valueOrNull ?? [])
            .map((n) => n.id == noteId ? updated : n)
            .toList(),
      );
    }
  }

  Future<void> reorderNotes(List<Note> reordered) async {
    final repo = ref.read(noteRepositoryProvider);
    final currentList = state.valueOrNull ?? [];
    final updatedList = currentList.map((note) {
      return reordered.firstWhere((n) => n.id == note.id, orElse: () => note);
    }).toList();

    state = AsyncData(updatedList);
    await repo.batchUpdate(reordered);
  }
}

final noteDetailProvider = FutureProvider.family<Note?, String>((ref, id) async {
  final repo = ref.read(noteRepositoryProvider);
  return repo.getById(id);
});
