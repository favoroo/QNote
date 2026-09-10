import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';

final journalServiceProvider = Provider<JournalService>((ref) {
  return JournalService.instance;
});

/// 按日期查询日记笔记，用于时间线悬浮按钮状态与编辑页初始化
/// 值为 null 或内容为空都视为"当天未写日记"
final journalByDateProvider = FutureProvider.family<Note?, DateTime>((
  ref,
  date,
) async {
  final service = ref.read(journalServiceProvider);
  return service.getNoteForDate(date);
});

/// 保存日记后统一失效相关 Provider（页面存活时用 ref，dispose 阶段用容器）
void invalidateJournal(ProviderContainer container, DateTime date) {
  container.invalidate(journalByDateProvider(date));
  container.invalidate(noteListProvider);
  container.invalidate(folderListProvider);
}
