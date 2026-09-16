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

  @override
  Future<List<Note>> build() async => _initial;
}

class _MockFolderListNotifier extends FolderListNotifier {
  final List<Folder> _initial;
  _MockFolderListNotifier(this._initial);

  @override
  Future<List<Folder>> build() async => _initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('笔记列表项渲染拖动手柄，且支持长按唤起操作菜单', (tester) async {
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
        child: const MaterialApp(
          home: Scaffold(
            body: NotesPage(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 验证笔记标题已渲染
    expect(find.text('测试笔记标题'), findsOneWidget);

    // 验证右侧呈现 drag_indicator 拖动手柄图标，且不再是 more_vert
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // 长按笔记项，测试是否能唤起 ActionMenu 操作菜单（包含「给小Q」、「编辑笔记」、「删除笔记」等）
    await tester.longPress(find.text('测试笔记标题'));
    await tester.pumpAndSettle();

    expect(find.text('给小Q'), findsOneWidget);
    expect(find.text('编辑笔记'), findsOneWidget);
    expect(find.text('删除笔记'), findsOneWidget);
  });

  testWidgets('文件夹列表项渲染拖动手柄，且支持长按唤起文件夹菜单', (tester) async {
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
        child: const MaterialApp(
          home: Scaffold(
            body: NotesPage(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 验证文件夹名称已渲染
    expect(find.text('测试文件夹'), findsOneWidget);

    // 验证文件夹右侧同样呈现 drag_indicator 拖动手柄图标
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // 长按文件夹项，测试是否能唤起文件夹 ActionMenu 操作菜单
    await tester.longPress(find.text('测试文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('重命名文件夹'), findsOneWidget);
    expect(find.text('删除文件夹'), findsOneWidget);
  });
}
