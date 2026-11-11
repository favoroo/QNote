import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/utils/note_tree_drag.dart';
import 'package:qnote_flutter/core/utils/reorder_gesture.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';

Note _note(
  String id, {
  String? folderId,
  int sortOrder = 0,
  bool pinned = false,
  int createdDay = 1,
  int updatedDay = 1,
}) {
  return Note(
    id: id,
    title: id,
    folderId: folderId,
    sortOrder: sortOrder,
    isPinned: pinned,
    createdAt: DateTime(2026, 1, createdDay),
    updatedAt: DateTime(2026, 1, updatedDay),
  );
}

Folder _folder(String id, {String? parentId, int sortOrder = 0, bool expanded = true, String? name}) {
  return Folder(
    id: id,
    name: name ?? id,
    parentId: parentId,
    sortOrder: sortOrder,
    isExpanded: expanded,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

List<String> _ids(List<Object> level) {
  return [
    for (final item in level)
      if (item is Note) 'n:${item.id}' else 'f:${(item as Folder).id}',
  ];
}

List<String> _levelIds(List<Folder> folders, List<Note> notes, {String? parentId}) {
  return _ids(buildNoteTreeLevel(folders: folders, notes: notes, parentId: parentId));
}

({List<Folder> folders, List<Note> notes}) _apply(
  NoteTreeDropPlan plan, {
  required List<Folder> folders,
  required List<Note> notes,
}) {
  final folderById = {for (final folder in plan.folders) folder.id: folder};
  final noteById = {for (final note in plan.notes) note.id: note};
  return (
    folders: [for (final folder in folders) folderById[folder.id] ?? folder],
    notes: [for (final note in notes) noteById[note.id] ?? note],
  );
}

void main() {
  final now = DateTime(2026, 2, 1, 12);

  group('buildNoteTreeLevel', () {
    test('置顶笔记永远在前，文件夹与普通笔记按 sortOrder 混排', () {
      final folders = [_folder('f1', sortOrder: 0, name: 'A'), _folder('f2', sortOrder: 0, name: 'B')];
      final notes = [
        _note('p1', sortOrder: 5, pinned: true, createdDay: 1),
        _note('p2', sortOrder: 1, pinned: true, createdDay: 2),
        _note('n1', sortOrder: 0, createdDay: 5),
        _note('n2', sortOrder: 1, createdDay: 4),
      ];

      expect(_levelIds(folders, notes), ['n:p2', 'n:p1', 'f:f1', 'f:f2', 'n:n1', 'n:n2']);
    });

    test('同序号笔记按创建时间倒序', () {
      final notes = [_note('old', sortOrder: 0, createdDay: 1), _note('new', sortOrder: 0, createdDay: 9)];

      expect(_levelIds([], notes), ['n:new', 'n:old']);
    });
  });

  group('isFolderSelfOrDescendant', () {
    test('识别自身与多层子孙', () {
      final folders = [_folder('f1'), _folder('f2', parentId: 'f1'), _folder('f3', parentId: 'f2')];

      expect(isFolderSelfOrDescendant(folderId: 'f2', ancestorId: 'f2', folders: folders), isTrue);
      expect(isFolderSelfOrDescendant(folderId: 'f3', ancestorId: 'f1', folders: folders), isTrue);
      expect(isFolderSelfOrDescendant(folderId: 'f1', ancestorId: 'f3', folders: folders), isFalse);
    });

    test('脏数据形成父子环时不会死循环', () {
      final folders = [_folder('a', parentId: 'b'), _folder('b', parentId: 'a')];

      expect(isFolderSelfOrDescendant(folderId: 'a', ancestorId: 'missing', folders: folders), isFalse);
    });
  });

  group('canDropNoteTreeItem', () {
    test('拒绝自身、日记节点与文件夹循环', () {
      final journalNote = _note(JournalService.noteId(DateTime(2026, 1, 1)));
      final journalFolder = Folder(
        id: JournalService.rootFolderId,
        name: '日记',
        type: JournalService.rootFolderType,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final folders = [_folder('f1'), _folder('f2', parentId: 'f1'), journalFolder];
      final notes = [_note('n1'), _note('n2', folderId: 'f2'), journalNote];

      expect(canDropNoteTreeItem(folders: folders, notes: notes, draggedId: 'n1', targetId: 'n1'), isFalse);
      expect(canDropNoteTreeItem(folders: folders, notes: notes, draggedId: journalNote.id, targetId: 'n1'), isFalse);
      expect(canDropNoteTreeItem(folders: folders, notes: notes, draggedId: 'n1', targetId: journalFolder.id), isFalse);
      expect(canDropNoteTreeItem(folders: folders, notes: notes, draggedId: 'f1', targetId: 'f2'), isFalse);
      expect(canDropNoteTreeItem(folders: folders, notes: notes, draggedId: 'f1', targetId: 'n2'), isFalse);
      expect(canDropNoteTreeItem(folders: folders, notes: notes, draggedId: 'f1', targetId: 'n1'), isTrue);
    });
  });

  group('planNoteTreeDrop', () {
    test('笔记拖到文件夹中部：移入并展开文件夹', () {
      final folders = [_folder('f1', expanded: false)];
      final notes = [_note('n1', sortOrder: 0), _note('child', folderId: 'f1', sortOrder: 0)];

      final plan = planNoteTreeDrop(
        folders: folders,
        notes: notes,
        draggedId: 'n1',
        targetId: 'f1',
        position: ReorderDropPosition.inside,
        now: now,
      );

      expect(plan, isNotNull);
      expect(plan!.destParentId, 'f1');
      expect(plan.notes.single.id, 'n1');
      expect(plan.notes.single.folderId, 'f1');
      expect(plan.notes.single.sortOrder, 1);
      expect(plan.notes.single.updatedAt, now);
      expect(plan.folders.single.id, 'f1');
      expect(plan.folders.single.isExpanded, isTrue);

      final applied = _apply(plan, folders: folders, notes: notes);
      expect(_levelIds(applied.folders, applied.notes, parentId: 'f1'), ['n:child', 'n:n1']);
    });

    test('已经在该文件夹末尾时返回 null', () {
      final folders = [_folder('f1')];
      final notes = [_note('c1', folderId: 'f1', sortOrder: 0), _note('c2', folderId: 'f1', sortOrder: 1)];

      expect(
        planNoteTreeDrop(
          folders: folders,
          notes: notes,
          draggedId: 'c2',
          targetId: 'f1',
          position: ReorderDropPosition.inside,
          now: now,
        ),
        isNull,
      );
    });

    test('跨文件夹 before 插入并重排目标层级', () {
      final folders = [_folder('f1'), _folder('f2')];
      final notes = [
        _note('a', folderId: 'f1', sortOrder: 0),
        _note('b', folderId: 'f2', sortOrder: 0, createdDay: 3),
        _note('c', folderId: 'f2', sortOrder: 1, createdDay: 2),
      ];

      final plan = planNoteTreeDrop(
        folders: folders,
        notes: notes,
        draggedId: 'a',
        targetId: 'b',
        position: ReorderDropPosition.before,
        now: now,
      );

      expect(plan, isNotNull);
      expect(plan!.destParentId, 'f2');
      final byId = {for (final note in plan.notes) note.id: note};
      expect(byId['a']!.folderId, 'f2');
      expect(byId['a']!.sortOrder, 0);
      expect(byId['b']!.sortOrder, 1);
      expect(byId['c']!.sortOrder, 2);

      final applied = _apply(plan, folders: folders, notes: notes);
      expect(_levelIds(applied.folders, applied.notes, parentId: 'f2'), ['n:a', 'n:b', 'n:c']);
      expect(_levelIds(applied.folders, applied.notes, parentId: 'f1'), isEmpty);
    });

    test('拖回原位时返回 null，不产生无意义的整层写入', () {
      final notes = [_note('n1', sortOrder: 0), _note('n2', sortOrder: 1)];

      expect(
        planNoteTreeDrop(
          folders: const [],
          notes: notes,
          draggedId: 'n1',
          targetId: 'n2',
          position: ReorderDropPosition.before,
          now: now,
        ),
        isNull,
      );
    });

    test('移至根目录时追加到根层级末尾', () {
      final folders = [_folder('f1')];
      final notes = [_note('a', folderId: 'f1', sortOrder: 0)];

      final plan = planNoteTreeDrop(
        folders: folders,
        notes: notes,
        draggedId: 'a',
        targetId: null,
        position: ReorderDropPosition.after,
        now: now,
      );

      expect(plan, isNotNull);
      expect(plan!.notes.single.folderId, isNull);
      expect(plan.notes.single.sortOrder, 1);

      final applied = _apply(plan, folders: folders, notes: notes);
      expect(_levelIds(applied.folders, applied.notes), ['f:f1', 'n:a']);
    });

    test('文件夹不能拖进自身或子孙目录', () {
      final folders = [_folder('f1'), _folder('f2', parentId: 'f1')];
      final notes = [_note('inside', folderId: 'f2')];

      expect(
        planNoteTreeDrop(
          folders: folders,
          notes: notes,
          draggedId: 'f1',
          targetId: 'f2',
          position: ReorderDropPosition.inside,
          now: now,
        ),
        isNull,
      );
      expect(
        planNoteTreeDrop(
          folders: folders,
          notes: notes,
          draggedId: 'f1',
          targetId: 'inside',
          position: ReorderDropPosition.before,
          now: now,
        ),
        isNull,
      );
    });

    test('日记节点不可拖出、也不可作为落点', () {
      final journalFolder = Folder(
        id: JournalService.rootFolderId,
        name: '日记',
        type: JournalService.rootFolderType,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      final journalNote = _note(JournalService.noteId(DateTime(2026, 1, 1)));
      final folders = [journalFolder, _folder('f1')];
      final notes = [journalNote, _note('n1')];

      expect(
        planNoteTreeDrop(
          folders: folders,
          notes: notes,
          draggedId: journalNote.id,
          targetId: 'f1',
          position: ReorderDropPosition.inside,
          now: now,
        ),
        isNull,
      );
      expect(
        planNoteTreeDrop(
          folders: folders,
          notes: notes,
          draggedId: 'n1',
          targetId: journalFolder.id,
          position: ReorderDropPosition.inside,
          now: now,
        ),
        isNull,
      );
    });

    test('置顶笔记重排后视觉顺序保持稳定', () {
      final folders = [_folder('f1', sortOrder: 2)];
      final notes = [
        _note('p0', sortOrder: 0, pinned: true, createdDay: 3),
        _note('p1', sortOrder: 1, pinned: true, createdDay: 2),
        _note('u1', sortOrder: 2, createdDay: 1),
      ];

      final plan = planNoteTreeDrop(
        folders: folders,
        notes: notes,
        draggedId: 'p1',
        targetId: 'p0',
        position: ReorderDropPosition.before,
        now: now,
      );

      expect(plan, isNotNull);
      final applied = _apply(plan!, folders: folders, notes: notes);
      expect(_levelIds(applied.folders, applied.notes), ['n:p1', 'n:p0', 'f:f1', 'n:u1']);
    });

    test('置顶笔记落到普通项上时收敛到置顶组末尾', () {
      final folders = [_folder('f1', sortOrder: 2)];
      final notes = [
        _note('p0', sortOrder: 0, pinned: true, createdDay: 3),
        _note('p1', sortOrder: 1, pinned: true, createdDay: 2),
        _note('u1', sortOrder: 2, createdDay: 1),
      ];

      final plan = planNoteTreeDrop(
        folders: folders,
        notes: notes,
        draggedId: 'p0',
        targetId: 'f1',
        position: ReorderDropPosition.after,
        now: now,
      );

      expect(plan, isNotNull);
      final applied = _apply(plan!, folders: folders, notes: notes);
      expect(_levelIds(applied.folders, applied.notes), ['n:p1', 'n:p0', 'f:f1', 'n:u1']);
    });

    test('普通笔记落到置顶项上时收敛到普通组开头', () {
      final notes = [
        _note('p0', sortOrder: 0, pinned: true, createdDay: 3),
        _note('u1', sortOrder: 1, createdDay: 2),
        _note('u2', sortOrder: 2, createdDay: 1),
      ];

      expect(
        planNoteTreeDrop(
          folders: const [],
          notes: notes,
          draggedId: 'u1',
          targetId: 'p0',
          position: ReorderDropPosition.before,
          now: now,
        ),
        isNull,
      );
    });
  });
}
