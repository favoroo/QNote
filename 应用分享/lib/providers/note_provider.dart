import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
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
    await refresh();
    return note;
  }

  Future<void> updateNote(Note note) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.update(note);
    await refresh();
  }

  Future<void> deleteNote(String id) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.softDelete(id);
    await refresh();
  }

  Future<void> togglePin(String id, bool isPinned) async {
    final repo = ref.read(noteRepositoryProvider);
    await repo.togglePin(id, isPinned);
    await refresh();
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
      await repo.update(note.copyWith(
        folderId: folderId,
        clearFolderId: folderId == null,
      ));
      await refresh();
    }
  }
}

final noteDetailProvider = FutureProvider.family<Note?, String>((ref, id) async {
  final repo = ref.read(noteRepositoryProvider);
  return repo.getById(id);
});
