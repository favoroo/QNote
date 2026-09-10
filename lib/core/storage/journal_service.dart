import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';

/// 每日日记服务：管理时间线"日记"功能对应的笔记数据。
///
/// 日记复用 notes / folders 表存储，无需单独建表：
/// - 根文件夹：固定 id，type = journal
/// - 月份子文件夹：id 形如 journal_month_2026-09，type = journal_month
/// - 日记笔记：id 形如 journal_note_2026-09-10，title = 2026-09-10
///
/// 固定 id 让结构创建天然幂等，且可通过 id 前缀直接识别日记数据，
/// 避免通过 folder 层级链路反查。
class JournalService {
  static final JournalService instance = JournalService._internal();
  JournalService._internal();

  static const String rootFolderId = 'journal_root';
  static const String rootFolderName = '日记';
  static const String rootFolderType = 'journal';
  static const String monthFolderType = 'journal_month';

  /// 日记笔记 id 前缀
  static const String noteIdPrefix = 'journal_note_';

  final FolderRepository _folderRepo = FolderRepository();
  final NoteRepository _noteRepo = NoteRepository();

  static String monthFolderId(DateTime date) => 'journal_month_${_ym(date)}';

  static String noteId(DateTime date) => 'journal_note_${_ymd(date)}';

  static String _ym(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  static String _ymd(DateTime d) =>
      '${_ym(d)}-${d.day.toString().padLeft(2, '0')}';

  /// 判断一条笔记是否为日记
  static bool isJournalNote(String id) => id.startsWith(noteIdPrefix);

  /// 判断一个文件夹是否属于日记体系（根或月份子文件夹）
  static bool isJournalFolder(Folder folder) =>
      folder.type == rootFolderType || folder.type == monthFolderType;

  /// 确保日记根文件夹存在（幂等）
  Future<Folder> ensureRootFolder() async {
    final existing = await _folderRepo.getById(rootFolderId);
    if (existing != null) return existing;

    final now = DateTime.now();
    final folder = Folder(
      id: rootFolderId,
      name: rootFolderName,
      parentId: null,
      type: rootFolderType,
      // 极小 sortOrder 保证日记文件夹固定排在普通文件夹之前
      sortOrder: -1000000000,
      createdAt: now,
      updatedAt: now,
    );
    try {
      await _folderRepo.insert(folder);
      return folder;
    } catch (_) {
      // 并发初始化时可能重复插入，回查一次保证幂等
      final again = await _folderRepo.getById(rootFolderId);
      if (again != null) return again;
      rethrow;
    }
  }

  /// 确保 YYYY-MM 月份子文件夹存在（幂等）
  Future<Folder> ensureMonthFolder(DateTime date) async {
    final id = monthFolderId(date);
    final existing = await _folderRepo.getById(id);
    if (existing != null) return existing;

    final now = DateTime.now();
    final folder = Folder(
      id: id,
      name: _ym(date),
      parentId: rootFolderId,
      type: monthFolderType,
      // 负月份序号：月份越新数值越小，排序后新月份在上
      sortOrder: -(date.year * 12 + date.month),
      createdAt: now,
      updatedAt: now,
    );
    try {
      await _folderRepo.insert(folder);
      return folder;
    } catch (_) {
      final again = await _folderRepo.getById(id);
      if (again != null) return again;
      rethrow;
    }
  }

  /// 查询某天的日记笔记，不存在或内容为空都视为"未写日记"。
  /// 历史版本可能落过空日记，读取时顺带自愈清理，避免笔记板块被空文件占满
  Future<Note?> getNoteForDate(DateTime date) async {
    final note = await _noteRepo.getById(noteId(date));
    if (note == null) return null;
    if (note.content.trim().isNotEmpty) return note;
    await _noteRepo.hardDelete(note.id);
    await _cleanupMonthFolder(date);
    return null;
  }

  /// 保存某天日记内容（upsert）：内容为空时视为删除当天日记，
  /// 空日记不落库，保证笔记板块里只出现有效内容
  Future<Note?> saveJournal(DateTime date, String content) async {
    final existing = await _noteRepo.getById(noteId(date));

    if (content.trim().isEmpty) {
      if (existing != null) {
        await _noteRepo.hardDelete(noteId(date));
        await _cleanupMonthFolder(date);
      }
      return null;
    }

    await ensureRootFolder();
    await ensureMonthFolder(date);

    final now = DateTime.now();
    if (existing == null) {
      final note = Note(
        id: noteId(date),
        title: _ymd(date),
        content: content,
        folderId: monthFolderId(date),
        // 负天数序号：日期越新数值越小，排序后新日记在上
        sortOrder: -date.difference(DateTime(1970, 1, 1)).inDays,
        createdAt: now,
        updatedAt: now,
      );
      await _noteRepo.insert(note);
      return note;
    }
    final updated = existing.copyWith(content: content, updatedAt: now);
    await _noteRepo.update(updated);
    return updated;
  }

  bool _emptyCleanedThisSession = false;

  /// 清理某月残留的空日记；若该月已无任何日记，连带删除月份子文件夹
  Future<void> _cleanupMonthFolder(DateTime date) =>
      _cleanupMonthFolderById(monthFolderId(date));

  Future<void> _cleanupMonthFolderById(String monthId) async {
    final notes = await _noteRepo.getByFolder(monthId);

    for (final note in notes) {
      if (note.content.trim().isEmpty) {
        await _noteRepo.hardDelete(note.id);
      }
    }

    if (!notes.any((n) => n.content.trim().isNotEmpty)) {
      await _folderRepo.delete(monthId);
    }
  }

  /// 会话级一次性清理全量空日记与空月份文件夹。
  /// 挂在 folderListProvider 构建时执行，保证笔记板块打开即干净；
  /// 单日残留另有 getNoteForDate 读取时自愈兜底
  Future<void> cleanupEmptyJournalsIfNeeded() async {
    if (_emptyCleanedThisSession) return;
    _emptyCleanedThisSession = true;

    final months = await _folderRepo.getByType(monthFolderType);
    for (final month in months) {
      await _cleanupMonthFolderById(month.id);
    }
  }
}
