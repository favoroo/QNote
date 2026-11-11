import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/refresh/refresh_failure_notice.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/color_mark_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:flutter/material.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';
import 'package:qnote_flutter/core/utils/widget_utils.dart';
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

/// 记录面板的草稿快照。
///
/// 从面板 State 里提出来放进 Provider，是为了让草稿活过面板的关闭：面板是模态
/// 底部弹层，误触遮罩就会销毁 State，草稿只存在 State 里会直接丢字。放在这里
/// 后还能顺带驱动左下角记录按钮的「有草稿」圆点。
class DiaryComposeDraft {
  final String id;
  final String inputText;
  final List<TagEntry> tagEntries;
  final List<String> selectedPhotos;
  final TimeOfDay startTime;
  final TimeOfDay? endTime;
  final int? startOffset;
  final int? endOffset;

  DiaryComposeDraft({
    required this.id,
    this.inputText = '',
    this.tagEntries = const [],
    this.selectedPhotos = const [],
    TimeOfDay? startTime,
    this.endTime,
    this.startOffset,
    this.endOffset,
  }) : startTime = startTime ?? TimeOfDay.now();

  Map<String, dynamic> getFormValuesFor(String tagId) {
    final entry = tagEntries.where((e) => e.id == tagId).firstOrNull;
    return entry != null ? Map<String, dynamic>.from(entry.fields) : {};
  }

  /// 是否是一份「什么都没填」的空草稿（决定按钮要不要亮圆点、保存按钮要不要禁用）
  bool get isEmpty =>
      inputText.trim().isEmpty && tagEntries.isEmpty && selectedPhotos.isEmpty;

  DiaryComposeDraft copyWith({
    String? id,
    String? inputText,
    List<TagEntry>? tagEntries,
    List<String>? selectedPhotos,
    TimeOfDay? startTime,
    bool clearEndTime = false,
    TimeOfDay? endTime,
    int? startOffset,
    bool clearStartOffset = false,
    int? endOffset,
    bool clearEndOffset = false,
  }) {
    return DiaryComposeDraft(
      id: id ?? this.id,
      inputText: inputText ?? this.inputText,
      tagEntries: tagEntries ?? this.tagEntries,
      selectedPhotos: selectedPhotos ?? this.selectedPhotos,
      startTime: startTime ?? this.startTime,
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      startOffset: clearStartOffset ? null : (startOffset ?? this.startOffset),
      endOffset: clearEndOffset ? null : (endOffset ?? this.endOffset),
    );
  }

  DiaryComposeDraft updateTagEntryFields(
    String tagId,
    Map<String, dynamic> fields,
  ) {
    final newEntries = tagEntries.map((e) {
      if (e.id == tagId) return e.copyWith(fields: fields);
      return e;
    }).toList();
    return copyWith(tagEntries: newEntries);
  }
}

/// 记录面板草稿。面板卸载后草稿仍在，重新打开时接着填。
final diaryComposeDraftProvider =
    NotifierProvider<DiaryComposeDraftNotifier, DiaryComposeDraft>(
      DiaryComposeDraftNotifier.new,
    );

class DiaryComposeDraftNotifier extends Notifier<DiaryComposeDraft> {
  @override
  DiaryComposeDraft build() => DiaryComposeDraft(id: const Uuid().v4());

  void set(DiaryComposeDraft draft) => state = draft;

  /// 保存成功或用户主动清空后重置为一份全新草稿。
  void reset() => state = DiaryComposeDraft(id: const Uuid().v4());
}

enum WidgetAction {
  input,
  photo,
  camera,
  send,
}

final pendingWidgetActionProvider = StateProvider<WidgetAction?>((ref) => null);

final currentInputTimeProvider = StateProvider<TimeOfDay>((ref) => TimeOfDay.now());

final diaryDraftsProvider = StateProvider<List<DiaryRecord>>((ref) => []);

final diaryScrollTriggerProvider = StateProvider<int>((ref) => 0);

final diaryScrollToTimeProvider = StateProvider<DateTime?>((ref) => null);

/// 刚由记录面板写下的记录 id，供时间线播「新卡片升起」的入场动画。
///
/// 用显式信号而不是「和上一次列表做差」：备份恢复、WebDAV 同步、批量提取都会一次
/// 冒出成批记录，按差集判定会让它们跟着一起炸开动画，而这里只认「用户刚记下的那条」。
/// 页面消费一次即清空。
final diaryJustInsertedProvider = StateProvider<List<String>>((ref) => const []);

final diaryListProvider =
    AsyncNotifierProvider<DiaryListNotifier, List<DiaryRecord>>(() {
      return DiaryListNotifier();
    });

class DiaryListNotifier extends AsyncNotifier<List<DiaryRecord>> {
  DiaryRecord? _lastDeleted;

  /// 小Q 虚拟工作区变更回调：/timeline/ 路径有写入时自动重查数据库，
  /// 避免 VFS 直接写库后内存列表与 UI 脱节（时间线看不到新增记录）
  void _onWorkspaceChange(WorkspaceChangeEvent event) {
    if (event.path.startsWith('/timeline/')) {
      refresh();
    }
  }

  @override
  Future<List<DiaryRecord>> build() async {
    // addListener 内部按引用去重，build 重复执行不会重复注册
    WorkspaceEventBus.instance.addListener(_onWorkspaceChange);
    ref.onDispose(
      () => WorkspaceEventBus.instance.removeListener(_onWorkspaceChange),
    );
    final repo = ref.read(diaryRepositoryProvider);
    return repo.getAll();
  }

  Future<void> refresh() async {
    final repo = ref.read(diaryRepositoryProvider);
    try {
      state = AsyncData(await repo.getAll());
    } catch (e, st) {
      RefreshFailureNotice.report(
        source: '日记',
        error: e,
        stackTrace: st,
        retry: () {
          refresh();
        },
      );
    }
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
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), record]);
    WidgetUtils.updateHomeWidgets();
    return record;
  }

  Future<void> updateDiary(DiaryRecord record, {bool updateWidgets = true}) async {
    final repo = ref.read(diaryRepositoryProvider);
    await repo.update(record);
    // 内存替换目标项
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((r) => r.id == record.id ? record : r)
          .toList(),
    );
    if (updateWidgets) {
      WidgetUtils.updateHomeWidgets();
    }
  }

  Future<void> deleteDiary(String id) async {
    final repo = ref.read(diaryRepositoryProvider);
    final currentList = state.valueOrNull ?? [];
    _lastDeleted = currentList.where((r) => r.id == id).firstOrNull;
    await repo.softDelete(id);
    // 内存移除（软删除后不再展示）
    state = AsyncData(
      (state.valueOrNull ?? []).where((r) => r.id != id).toList(),
    );
    WidgetUtils.updateHomeWidgets();
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
    // 内存加回（恢复）
    state = AsyncData([...(state.valueOrNull ?? []), restored]);
    WidgetUtils.updateHomeWidgets();
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

/// 按时间范围拉取日记记录（statistics_page 专用，避免全量加载）
/// 自动响应 diaryListProvider 变更（增删改后 invalidate）
final diaryListByDateRangeProvider = FutureProvider.family<
    List<DiaryRecord>, ({DateTime start, DateTime end})>((ref, range) async {
  // 监听 diaryListProvider：用户增删改日记后，本 provider 自动失效重算
  ref.watch(diaryListProvider);
  final repo = ref.read(diaryRepositoryProvider);
  return repo.getByDateRange(range.start, range.end);
});

/// 日期颜色标记的异步通知器
class DiaryColorMarkNotifier extends AsyncNotifier<List<DateColorMark>> {
  @override
  Future<List<DateColorMark>> build() async {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path.contains('color_marks') || event.path.startsWith('/timeline/')) {
        refresh();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });

    final repo = ref.read(colorMarkRepositoryProvider);
    return repo.getAll();
  }

  Future<void> refresh() async {
    final repo = ref.read(colorMarkRepositoryProvider);
    state = AsyncData(await repo.getAll());
  }

  Future<void> setMark(DateColorMark mark) async {
    final repo = ref.read(colorMarkRepositoryProvider);
    await repo.insert(mark);
    await refresh();
  }

  Future<void> removeMark(String id) async {
    final repo = ref.read(colorMarkRepositoryProvider);
    await repo.delete(id);
    await refresh();
  }

  Future<void> removeMarkByDate(DateTime date) async {
    final repo = ref.read(colorMarkRepositoryProvider);
    await repo.deleteByDate(date);
    await refresh();
  }
}

final diaryColorMarkProvider =
    AsyncNotifierProvider<DiaryColorMarkNotifier, List<DateColorMark>>(() {
      return DiaryColorMarkNotifier();
    });
