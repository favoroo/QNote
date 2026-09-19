import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';

/// 编辑器的 initState 会往 floatingQProvider 里注册页面上下文，
/// 而 Riverpod 禁止在 widget 生命周期内改 provider（本用例与保存语义无关，直接置空）。
class _NoopFloatingQNotifier extends FloatingQNotifier {
  @override
  void pushOverlayContext(QPageContext context) {}

  @override
  void popOverlayContext(QPageContext context) {}
}

/// 记录写入调用的正常 provider
class _RecordingNoteListNotifier extends NoteListNotifier {
  final Note note;
  final List<Note> updates = [];

  _RecordingNoteListNotifier(this.note);

  @override
  Future<List<Note>> build() async => [note];

  @override
  Future<void> updateNote(Note updated) async {
    updates.add(updated);
  }
}

/// 写库必然失败的 provider，用于验证「保存失败不许退出」
class _FailingNoteListNotifier extends _RecordingNoteListNotifier {
  _FailingNoteListNotifier(super.note);

  @override
  Future<void> updateNote(Note updated) async {
    updates.add(updated);
    throw Exception('database is locked');
  }
}

Note _buildNote({String title = '既有标题', String content = '既有内容'}) {
  return Note(
    id: 'note-1',
    title: title,
    content: content,
    createdAt: DateTime(2026, 9, 19),
    updatedAt: DateTime(2026, 9, 19),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingNoteListNotifier notifier;

  /// 把编辑器推上导航栈，便于断言「是否真的退出了」
  Future<void> openEditor(
    WidgetTester tester, {
    required Note note,
    bool failSave = false,
  }) async {
    notifier = failSave ? _FailingNoteListNotifier(note) : _RecordingNoteListNotifier(note);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noteListProvider.overrideWith(() => notifier),
          floatingQProvider.overrideWith(() => _NoopFloatingQNotifier()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteEditorView(note: note),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pressBack(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> editTitle(WidgetTester tester, String text) async {
    final titleField = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(TextField),
    );
    await tester.enterText(titleField, text);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 排干 Toast 与自动保存定时器等挂起 Timer
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('NoteEditorView 保存链路', () {
    testWidgets('刚打开即「已保存」，空标题笔记返回也不会被判脏', (tester) async {
      await openEditor(tester, note: _buildNote(title: '', content: '内容'));

      expect(find.text('已保存'), findsOneWidget);

      await pressBack(tester);
      // 标题基线口径不一致会让空标题笔记一进来就白写一次库
      expect(notifier.updates, isEmpty);
      expect(find.text('open'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('改标题后转「未保存」，退出时才写入', (tester) async {
      await openEditor(tester, note: _buildNote());

      await editTitle(tester, '改了标题');
      expect(find.text('未保存'), findsOneWidget);
      expect(notifier.updates, isEmpty);

      await pressBack(tester);

      expect(notifier.updates, hasLength(1));
      expect(notifier.updates.single.title, '改了标题');
      expect(find.text('open'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('写库失败时不退出、给可重试提示，内容仍停在未保存', (tester) async {
      await openEditor(tester, note: _buildNote(), failSave: true);

      await editTitle(tester, '还没存下去的标题');
      await pressBack(tester);

      expect(notifier.updates, hasLength(1));
      // 关键断言：仍停在编辑页，而不是假装保存成功就退出
      expect(find.byType(NoteEditorView), findsOneWidget);
      expect(find.text('open'), findsNothing);
      expect(find.textContaining('保存失败'), findsOneWidget);
      // 基线未推进，所以状态依然是未保存
      expect(find.text('未保存'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('保存失败后再次返回会重试写入同一版内容', (tester) async {
      await openEditor(tester, note: _buildNote(), failSave: true);

      await editTitle(tester, '重试标题');
      await pressBack(tester);
      await pressBack(tester);

      expect(notifier.updates, hasLength(2));
      expect(notifier.updates.last.title, '重试标题');
      expect(find.byType(NoteEditorView), findsOneWidget);

      await drainTimers(tester);
    });
  });
}
