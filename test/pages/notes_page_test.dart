import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/pages/notes_page.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockNoteListNotifier extends NoteListNotifier {
  final List<Note> _initial;
  _MockNoteListNotifier(this._initial);

  final List<Note> saved = [];

  @override
  Future<List<Note>> build() async => _initial;

  @override
  Future<void> reorderNotes(List<Note> reordered) async {
    saved.addAll(reordered);
    final byId = {for (final note in reordered) note.id: note};
    state = AsyncData([for (final note in state.valueOrNull ?? _initial) byId[note.id] ?? note]);
  }
}

class _MockFolderListNotifier extends FolderListNotifier {
  final List<Folder> _initial;
  _MockFolderListNotifier(this._initial);

  final List<Folder> saved = [];

  @override
  Future<List<Folder>> build() async => _initial;

  @override
  Future<void> reorderFolders(List<Folder> reordered) async {
    saved.addAll(reordered);
    final byId = {for (final folder in reordered) folder.id: folder};
    state = AsyncData([for (final folder in state.valueOrNull ?? _initial) byId[folder.id] ?? folder]);
  }
}

Future<void> _dragNoteTo(WidgetTester tester, Finder note, Offset target) async {
  final gesture = await tester.startGesture(tester.getCenter(note));
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('笔记列表项支持整行长按拾起，原地松手唤起操作菜单', (tester) async {
    final note = Note(
      id: 'note-1',
      title: '测试笔记标题',
      content: '测试内容',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteListProvider.overrideWith(() => _MockNoteListNotifier([note])),
          folderListProvider.overrideWith(() => _MockFolderListNotifier([])),
        ],
        child: const MaterialApp(home: Scaffold(body: NotesPage())),
      ),
    );

    await tester.pumpAndSettle();

    // 验证笔记标题已渲染
    expect(find.text('测试笔记标题'), findsOneWidget);

    // 移动端不再渲染六点手柄，改为整行长按拾起（LongPressDraggable）
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is LongPressDraggable), findsOneWidget);

    // 长按笔记项后原地松手，应唤起 ActionMenu 操作菜单（包含「给小Q」、「编辑笔记」、「删除笔记」等）
    await tester.longPress(find.text('测试笔记标题'));
    await tester.pumpAndSettle();

    expect(find.text('给小Q'), findsOneWidget);
    expect(find.text('编辑笔记'), findsOneWidget);
    expect(find.text('删除笔记'), findsOneWidget);
  });

  testWidgets('文件夹列表项支持整行长按拾起，原地松手唤起文件夹菜单', (tester) async {
    final folder = Folder(
      id: 'folder-1',
      name: '测试文件夹',
      type: 'note',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteListProvider.overrideWith(() => _MockNoteListNotifier([])),
          folderListProvider.overrideWith(() => _MockFolderListNotifier([folder])),
        ],
        child: const MaterialApp(home: Scaffold(body: NotesPage())),
      ),
    );

    await tester.pumpAndSettle();

    // 验证文件夹名称已渲染
    expect(find.text('测试文件夹'), findsOneWidget);

    // 移动端不画六点手柄，整行长按拾起；文件夹同样支持长按后原地松手弹菜单
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is LongPressDraggable), findsOneWidget);

    // 长按文件夹项后原地松手，应唤起文件夹 ActionMenu 操作菜单
    await tester.longPress(find.text('测试文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('重命名文件夹'), findsOneWidget);
    expect(find.text('删除文件夹'), findsOneWidget);
  });

  testWidgets('长按笔记拖到文件夹中部会移入文件夹并展开', (tester) async {
    final now = DateTime.now();
    final noteMock = _MockNoteListNotifier([
      Note(id: 'note-1', title: '可拖拽笔记', sortOrder: 0, createdAt: now, updatedAt: now),
    ]);
    final folderMock = _MockFolderListNotifier([
      Folder(id: 'folder-1', name: '目标文件夹', sortOrder: 1, isExpanded: false, createdAt: now, updatedAt: now),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [noteListProvider.overrideWith(() => noteMock), folderListProvider.overrideWith(() => folderMock)],
        child: const MaterialApp(home: Scaffold(body: NotesPage())),
      ),
    );
    await tester.pumpAndSettle();

    await _dragNoteTo(tester, find.text('可拖拽笔记'), tester.getCenter(find.text('目标文件夹')));

    final savedNote = noteMock.saved.lastWhere((note) => note.id == 'note-1');
    expect(savedNote.folderId, 'folder-1');
    expect(folderMock.saved.any((folder) => folder.id == 'folder-1' && folder.isExpanded), isTrue);
    // 真实拖动过，不应误弹长按菜单
    expect(find.text('重命名文件夹'), findsNothing);
  });

  testWidgets('拖到文件夹上沿只调整同级顺序，不改变所属文件夹', (tester) async {
    final now = DateTime.now();
    final noteMock = _MockNoteListNotifier([
      Note(id: 'note-1', title: '可拖拽笔记', sortOrder: 0, createdAt: now, updatedAt: now),
    ]);
    final folderMock = _MockFolderListNotifier([
      Folder(id: 'folder-mid', name: '中间文件夹', sortOrder: 1, createdAt: now, updatedAt: now),
      Folder(id: 'folder-1', name: '目标文件夹', sortOrder: 2, isExpanded: false, createdAt: now, updatedAt: now),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [noteListProvider.overrideWith(() => noteMock), folderListProvider.overrideWith(() => folderMock)],
        child: const MaterialApp(home: Scaffold(body: NotesPage())),
      ),
    );
    await tester.pumpAndSettle();

    final folderCenter = tester.getCenter(find.text('目标文件夹'));
    // 行高约 44px，中心上方 18px 落在上沿 22% 插入带内
    await _dragNoteTo(tester, find.text('可拖拽笔记'), folderCenter - const Offset(0, 18));

    final savedNote = noteMock.saved.lastWhere((note) => note.id == 'note-1');
    expect(savedNote.folderId, isNull);
    expect(savedNote.sortOrder, 1);
    // 上沿落点只重排同级，不应把目标文件夹标记为展开
    expect(folderMock.saved.any((folder) => folder.id == 'folder-1'), isFalse);
  });

  testWidgets('桌面端行尾手柄拖到文件夹中部同样能移入', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final now = DateTime.now();
      final noteMock = _MockNoteListNotifier([
        Note(id: 'note-1', title: '可拖拽笔记', sortOrder: 0, createdAt: now, updatedAt: now),
      ]);
      final folderMock = _MockFolderListNotifier([
        Folder(id: 'folder-1', name: '目标文件夹', sortOrder: 1, isExpanded: false, createdAt: now, updatedAt: now),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [noteListProvider.overrideWith(() => noteMock), folderListProvider.overrideWith(() => folderMock)],
          child: const MaterialApp(home: Scaffold(body: NotesPage())),
        ),
      );
      await tester.pumpAndSettle();

      // 桌面端只有行尾手柄可拖：笔记行与文件夹行各一个
      final noteTile = find.byKey(const ValueKey('note_note-1'));
      final noteHandle = find.descendant(of: noteTile, matching: find.byIcon(Icons.drag_indicator));
      expect(noteHandle, findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));

      final gesture = await tester.startGesture(tester.getCenter(noteHandle), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(0, 2));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('目标文件夹')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final savedNote = noteMock.saved.lastWhere((note) => note.id == 'note-1');
      expect(savedNote.folderId, 'folder-1');
      expect(folderMock.saved.any((folder) => folder.id == 'folder-1' && folder.isExpanded), isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
