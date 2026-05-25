import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/color_mark_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:flutter/material.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';
export 'package:qnote_flutter/providers/selected_date_provider.dart';

class TimelineTimeSelectEvent {
  final TimeOfDay time;
  final TimeOfDay? endTime;
  final DateTime date;
  final DateTime? endDate;
  final int timestamp;
  TimelineTimeSelectEvent(this.time, {this.endTime, required this.date, this.endDate}) : timestamp = DateTime.now().millisecondsSinceEpoch;
}

final diaryRepositoryProvider = Provider<DiaryRepository>((ref) {
  return DiaryRepository();
});

final colorMarkRepositoryProvider = Provider<ColorMarkRepository>((ref) {
  return ColorMarkRepository();
});

final colorMarkProvider = FutureProvider<DateColorMark?>((ref) async {
  final selectedDate = ref.watch(selectedDateProvider);
  final repo = ref.read(colorMarkRepositoryProvider);
  return repo.getByDate(selectedDate);
});

final diaryInputTimeProvider = StateProvider<TimelineTimeSelectEvent?>((ref) => null);

final currentInputTimeProvider = StateProvider<TimeOfDay>((ref) => TimeOfDay.now());

final diaryDraftsProvider = StateProvider<List<DiaryRecord>>((ref) => []);

final diaryScrollTriggerProvider = StateProvider<int>((ref) => 0);

final diaryScrollToTimeProvider = StateProvider<DateTime?>((ref) => null);

final diaryListProvider =
    AsyncNotifierProvider<DiaryListNotifier, List<DiaryRecord>>(() {
      return DiaryListNotifier();
    });

class DiaryListNotifier extends AsyncNotifier<List<DiaryRecord>> {
  DiaryRecord? _lastDeleted;

  @override
  Future<List<DiaryRecord>> build() async {
    final repo = ref.read(diaryRepositoryProvider);
    return repo.getAll();
  }

  Future<void> refresh() async {
    final repo = ref.read(diaryRepositoryProvider);
    state = AsyncData(await repo.getAll());
  }

  Future<void> loadByDate(DateTime date) async {
    final repo = ref.read(diaryRepositoryProvider);
    state = AsyncData(await repo.getByDate(date));
  }

  Future<DiaryRecord> addDiary({
    required String title,
    String content = '',
    int mood = 3,
    String weather = '',
    List<String> tags = const [],
    String? folderId,
    DateTime? time,
    DateTime? startTime,
    DateTime? endTime,
    String displayTag = '',
    Map<String, dynamic>? bodyState,
    List<TagEntry> tagEntries = const [],
    List<String> photos = const [],
  }) async {
    final repo = ref.read(diaryRepositoryProvider);
    final now = DateTime.now();
    final record = DiaryRecord(
      id: const Uuid().v4(),
      title: title,
      time: time ?? now,
      startTime: startTime,
      endTime: endTime,
      content: content,
      mood: mood,
      weather: weather,
      tags: tags,
      displayTag: displayTag,
      bodyState: bodyState,
      tagEntries: tagEntries,
      photos: photos,
      folderId: folderId,
      createdAt: now,
      updatedAt: now,
    );
    await repo.insert(record);
    await refresh();
    return record;
  }

  Future<void> updateDiary(DiaryRecord record) async {
    final repo = ref.read(diaryRepositoryProvider);
    await repo.update(record);
    await refresh();
  }

  Future<void> deleteDiary(String id) async {
    final repo = ref.read(diaryRepositoryProvider);
    final currentList = state.valueOrNull ?? [];
    _lastDeleted = currentList.where((r) => r.id == id).firstOrNull;
    await repo.softDelete(id);
    await refresh();
  }

  Future<void> undoDelete() async {
    if (_lastDeleted == null) return;
    final repo = ref.read(diaryRepositoryProvider);
    final restored = _lastDeleted!.copyWith(
      isDeleted: false,
      updatedAt: DateTime.now(),
    );
    await repo.update(restored);
    _lastDeleted = null;
    await refresh();
  }

  void addDraft(DiaryRecord draft) {
    final drafts = ref.read(diaryDraftsProvider);
    ref.read(diaryDraftsProvider.notifier).state = [...drafts, draft];
  }

  void removeDraft(String id) {
    final drafts = ref.read(diaryDraftsProvider);
    ref.read(diaryDraftsProvider.notifier).state = drafts
        .where((d) => d.id != id)
        .toList();
  }

  void updateDraft(DiaryRecord draft) {
    final drafts = ref.read(diaryDraftsProvider);
    ref.read(diaryDraftsProvider.notifier).state = drafts
        .map((d) => d.id == draft.id ? draft : d)
        .toList();
  }

  Future<void> searchDiary(String keyword) async {
    final repo = ref.read(diaryRepositoryProvider);
    if (keyword.isEmpty) {
      await refresh();
      return;
    }
    state = AsyncData(await repo.search(keyword));
  }
}

final diaryDetailProvider = FutureProvider.family<DiaryRecord?, String>((
  ref,
  id,
) async {
  final repo = ref.read(diaryRepositoryProvider);
  return repo.getById(id);
});

class DiaryColorMarkNotifier extends StateNotifier<List<DateColorMark>> {
  final ColorMarkRepository _repo;

  DiaryColorMarkNotifier(this._repo) : super([]);

  Future<void> loadAll() async {
    state = await _repo.getAll();
  }

  Future<void> setMark(DateColorMark mark) async {
    await _repo.insert(mark);
    await loadAll();
  }

  Future<void> removeMark(String id) async {
    await _repo.delete(id);
    await loadAll();
  }

  Future<void> removeMarkByDate(DateTime date) async {
    await _repo.deleteByDate(date);
    await loadAll();
  }
}

final diaryColorMarkProvider =
    StateNotifierProvider<DiaryColorMarkNotifier, List<DateColorMark>>((ref) {
      return DiaryColorMarkNotifier(ref.read(colorMarkRepositoryProvider));
    });
