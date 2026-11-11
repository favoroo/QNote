import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/utils/reorder_gesture.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';

/// 笔记树中单个层级的展示顺序。
///
/// 规则与页面渲染保持一致：置顶笔记永远排在最前；其余文件夹与未置顶笔记
/// 按 `sortOrder` 混排，同序号时文件夹优先，其次笔记按创建时间倒序、文件夹按名称。
///
/// 拖拽落点计算也复用这一顺序，保证「松手时看到的顺序」与「落库后的顺序」一致。
List<Object> buildNoteTreeLevel({required List<Folder> folders, required List<Note> notes, required String? parentId}) {
  final levelNotes = notes.where((note) => note.folderId == parentId).toList();
  final pinnedNotes = levelNotes.where((note) => note.isPinned).toList()..sort(_comparePinnedNotes);
  final sortableItems = <Object>[
    ...levelNotes.where((note) => !note.isPinned),
    ...folders.where((folder) => folder.parentId == parentId),
  ]..sort(compareNoteTreeSortables);

  return <Object>[...pinnedNotes, ...sortableItems];
}

/// 文件夹与未置顶笔记混排时的比较器。
int compareNoteTreeSortables(Object a, Object b) {
  final aOrder = a is Note ? a.sortOrder : (a as Folder).sortOrder;
  final bOrder = b is Note ? b.sortOrder : (b as Folder).sortOrder;
  if (aOrder != bOrder) return aOrder.compareTo(bOrder);

  if (a is Note && b is Note) {
    return b.createdAt.compareTo(a.createdAt);
  }
  if (a is Folder && b is Folder) {
    return a.name.compareTo(b.name);
  }
  // 同序号时文件夹在前，与列表分组习惯一致
  return a is Folder ? -1 : 1;
}

int _comparePinnedNotes(Note a, Note b) {
  if (a.sortOrder != b.sortOrder) return a.sortOrder.compareTo(b.sortOrder);
  final byUpdatedAt = b.updatedAt.compareTo(a.updatedAt);
  if (byUpdatedAt != 0) return byUpdatedAt;
  return b.createdAt.compareTo(a.createdAt);
}

/// [folderId] 是否就是 [ancestorId] 本身，或位于它的子孙层级。
///
/// 带 visited 集合防止脏数据形成父子环时死循环。
bool isFolderSelfOrDescendant({required String folderId, required String ancestorId, required List<Folder> folders}) {
  final folderById = <String, Folder>{for (final folder in folders) folder.id: folder};
  String? current = folderId;
  final visited = <String>{};

  while (current != null && visited.add(current)) {
    if (current == ancestorId) return true;
    current = folderById[current]?.parentId;
  }
  return false;
}

/// 判断 [draggedId] 能否落到 [targetId] 上（不区分行内 before/inside/after）。
///
/// 拒绝：拖到自身、日记体系节点、把文件夹拖进自身或子孙目录。
bool canDropNoteTreeItem({
  required List<Folder> folders,
  required List<Note> notes,
  required String draggedId,
  required String targetId,
}) {
  if (draggedId == targetId) return false;

  final draggedNote = notes.where((note) => note.id == draggedId).firstOrNull;
  final draggedFolder = folders.where((folder) => folder.id == draggedId).firstOrNull;
  if (draggedNote == null && draggedFolder == null) return false;
  if (draggedNote != null && JournalService.isJournalNote(draggedNote.id)) return false;
  if (draggedFolder != null && JournalService.isJournalFolder(draggedFolder)) return false;

  final targetNote = notes.where((note) => note.id == targetId).firstOrNull;
  final targetFolder = folders.where((folder) => folder.id == targetId).firstOrNull;
  if (targetNote == null && targetFolder == null) return false;
  if (targetNote != null && JournalService.isJournalNote(targetNote.id)) return false;
  if (targetFolder != null && JournalService.isJournalFolder(targetFolder)) return false;

  if (draggedFolder != null) {
    // 目标文件夹本身或它所在的父级只要落在被拖文件夹的子树内，都会形成环
    if (targetFolder != null &&
        isFolderSelfOrDescendant(folderId: targetFolder.id, ancestorId: draggedFolder.id, folders: folders)) {
      return false;
    }
    final targetParentId = targetNote?.folderId;
    if (targetParentId != null &&
        isFolderSelfOrDescendant(folderId: targetParentId, ancestorId: draggedFolder.id, folders: folders)) {
      return false;
    }
  }

  return true;
}

/// 一次笔记树拖拽落库计划：只包含真正发生变化的行。
class NoteTreeDropPlan {
  const NoteTreeDropPlan({required this.notes, required this.folders, required this.destParentId});

  /// 需要批量写库的笔记
  final List<Note> notes;

  /// 需要批量写库的文件夹（含移入后需要展开的目标文件夹）
  final List<Folder> folders;

  /// 落点所在层级；null 表示根目录
  final String? destParentId;

  bool get isEmpty => notes.isEmpty && folders.isEmpty;
}

/// 把一次拖拽落点转换为需要持久化的笔记/文件夹变更。
///
/// [targetId] 为 null 表示「移至根目录并追加到末尾」；否则 [position] 描述
/// 落点在目标行内的位置。非法落点、无实际变化均返回 null。
NoteTreeDropPlan? planNoteTreeDrop({
  required List<Folder> folders,
  required List<Note> notes,
  required String draggedId,
  required String? targetId,
  required ReorderDropPosition position,
  DateTime? now,
}) {
  final timestamp = now ?? DateTime.now();

  final draggedNote = notes.where((note) => note.id == draggedId).firstOrNull;
  final draggedFolder = folders.where((folder) => folder.id == draggedId).firstOrNull;
  if (draggedNote == null && draggedFolder == null) return null;
  if (draggedNote != null && JournalService.isJournalNote(draggedNote.id)) return null;
  if (draggedFolder != null && JournalService.isJournalFolder(draggedFolder)) return null;

  if (targetId != null &&
      !canDropNoteTreeItem(folders: folders, notes: notes, draggedId: draggedId, targetId: targetId)) {
    return null;
  }

  final targetFolder = targetId == null ? null : folders.where((folder) => folder.id == targetId).firstOrNull;
  final targetNote = targetId == null ? null : notes.where((note) => note.id == targetId).firstOrNull;

  String? destParentId;
  if (targetId == null) {
    destParentId = null;
  } else if (position == ReorderDropPosition.inside) {
    if (targetFolder == null) return null;
    destParentId = targetFolder.id;
  } else {
    destParentId = targetFolder?.parentId ?? targetNote?.folderId;
  }

  final level = buildNoteTreeLevel(folders: folders, notes: notes, parentId: destParentId);
  final siblings = level.where((item) {
    if (item is Note) return item.id != draggedId;
    if (item is Folder) return item.id != draggedId;
    return false;
  }).toList();

  final draggedIsPinned = draggedNote?.isPinned ?? false;
  final remainingPinnedCount = siblings.where(_isPinnedItem).length;

  // 置顶笔记永远在层级最前，落点跨组时收敛到组边界，
  // 保证重新编号后的视觉顺序与这里构造的顺序完全一致。
  int insertIndex;
  if (targetId == null || position == ReorderDropPosition.inside) {
    insertIndex = draggedIsPinned ? remainingPinnedCount : siblings.length;
  } else {
    final target = level.where((item) => _itemId(item) == targetId).firstOrNull;
    if (target == null) return null;
    final targetIsPinned = _isPinnedItem(target);
    if (draggedIsPinned != targetIsPinned) {
      // 置顶项落向普通项：放到置顶组末尾；普通项落向置顶项：放到普通组开头
      insertIndex = remainingPinnedCount;
    } else {
      final targetIndex = siblings.indexWhere((item) => _itemId(item) == targetId);
      if (targetIndex == -1) return null;
      insertIndex = position == ReorderDropPosition.before ? targetIndex : targetIndex + 1;
    }
  }

  final ordered = <Object>[...siblings];
  ordered.insert(insertIndex, draggedFolder ?? draggedNote!);

  final noteById = <String, Note>{for (final note in notes) note.id: note};
  final folderById = <String, Folder>{for (final folder in folders) folder.id: folder};

  final changedNotes = <Note>[];
  final changedFolders = <Folder>[];

  // 同一层级内「拖出去又拖回原位」时视觉顺序可能没变：此时不重排 sortOrder，
  // 避免置顶笔记等场景产生一次看似有、实际没有变化的整层写入。
  if (!_sameIdOrder(ordered, level)) {
    for (var index = 0; index < ordered.length; index++) {
      final item = ordered[index];
      if (item is Note) {
        final base = noteById[item.id];
        if (base == null) continue;
        final updated = base.copyWith(folderId: destParentId, clearFolderId: destParentId == null, sortOrder: index);
        if (updated.folderId == base.folderId && updated.sortOrder == base.sortOrder) continue;
        changedNotes.add(updated.copyWith(updatedAt: timestamp));
      } else if (item is Folder) {
        final base = folderById[item.id];
        if (base == null) continue;
        final updated = base.copyWith(parentId: destParentId, clearParentId: destParentId == null, sortOrder: index);
        if (updated.parentId == base.parentId && updated.sortOrder == base.sortOrder) continue;
        changedFolders.add(updated.copyWith(updatedAt: timestamp));
      }
    }
  }

  // 移入折叠文件夹时顺手展开，否则用户会误以为拖拽失败（内容看不见）
  if (position == ReorderDropPosition.inside && targetFolder != null && !targetFolder.isExpanded) {
    final expanded = targetFolder.copyWith(isExpanded: true, updatedAt: timestamp);
    if (!changedFolders.any((folder) => folder.id == expanded.id)) {
      changedFolders.add(expanded);
    }
  }

  if (changedNotes.isEmpty && changedFolders.isEmpty) return null;
  return NoteTreeDropPlan(notes: changedNotes, folders: changedFolders, destParentId: destParentId);
}

String _itemId(Object item) {
  if (item is Note) return item.id;
  return (item as Folder).id;
}

bool _isPinnedItem(Object item) => item is Note && item.isPinned;

bool _sameIdOrder(List<Object> a, List<Object> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (_itemId(a[index]) != _itemId(b[index])) return false;
  }
  return true;
}
