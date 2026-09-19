import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/widgets/diary/diary_editor_view.dart';

/// 编辑器 initState 会往 floatingQProvider 注册页面上下文，
/// Riverpod 禁止在 widget 生命周期内改 provider，与本用例无关故置空
class _NoopFloatingQNotifier extends FloatingQNotifier {
  @override
  void pushOverlayContext(QPageContext context) {}

  @override
  void popOverlayContext(QPageContext context) {}
}

class _MockDiaryListNotifier extends DiaryListNotifier {
  final DiaryRecord record;
  final List<DiaryRecord> saves = [];
  bool failUpdate;

  _MockDiaryListNotifier(this.record, {this.failUpdate = false});

  @override
  Future<List<DiaryRecord>> build() async => [record];

  @override
  Future<void> updateDiary(DiaryRecord updated, {bool updateWidgets = true}) async {
    saves.add(updated);
    if (failUpdate) {
      throw Exception('database is locked');
    }
  }
}

DiaryRecord _buildRecord() {
  return DiaryRecord(
    id: 'rec-1',
    title: '一条流水记录',
    time: DateTime(2026, 9, 19, 10, 30),
    content: '原始正文',
    createdAt: DateTime(2026, 9, 19),
    updatedAt: DateTime(2026, 9, 19),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockDiaryListNotifier diaryNotifier;

  Future<void> openEditor(WidgetTester tester, {bool failUpdate = false}) async {
    final record = _buildRecord();
    diaryNotifier = _MockDiaryListNotifier(record, failUpdate: failUpdate);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          diaryListProvider.overrideWith(() => diaryNotifier),
          floatingQProvider.overrideWith(() => _NoopFloatingQNotifier()),
          shortcutListProvider.overrideWith((ref) async => <ShortcutConfig>[]),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => DiaryEditorView(record: record)),
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

  Future<void> editContent(WidgetTester tester, String text) async {
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    await tester.enterText(field, text);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 排干 Toast 等挂起定时器
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));
  }

  bool saveButtonEnabled(WidgetTester tester) {
    return tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存修改'))
        .enabled;
  }

  group('DiaryEditorView 未保存保护', () {
    testWidgets('未作任何修改时直接返回，不该弹确认框', (tester) async {
      await openEditor(tester);

      expect(find.text('已保存'), findsOneWidget);
      // 没有待保存内容时按钮置灰，亮/灰本身就是状态指示
      expect(saveButtonEnabled(tester), isFalse);

      await pressBack(tester);

      // 基线错位会造成「没改也弹」，比原来的静默丢弃更惹人烦
      expect(find.text('未保存的更改'), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(diaryNotifier.saves, isEmpty);

      await drainTimers(tester);
    });

    testWidgets('改了正文后返回必须弹出保存/放弃/取消三选', (tester) async {
      await openEditor(tester);

      await editContent(tester, '手打的新内容');
      expect(find.text('未保存'), findsOneWidget);
      expect(saveButtonEnabled(tester), isTrue);

      await pressBack(tester);

      expect(find.text('未保存的更改'), findsOneWidget);
      expect(find.text('这条记录有未保存的修改，离开后将丢失。'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('放弃更改'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      // 仍在编辑页
      expect(find.byType(DiaryEditorView), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('确认框选「取消」留在原页且不写库', (tester) async {
      await openEditor(tester);
      await editContent(tester, '先别走');
      await pressBack(tester);

      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DiaryEditorView), findsOneWidget);
      expect(diaryNotifier.saves, isEmpty);

      await drainTimers(tester);
    });

    testWidgets('选「放弃更改」退出但不写库', (tester) async {
      await openEditor(tester);
      await editContent(tester, '不要了');
      await pressBack(tester);

      await tester.tap(find.text('放弃更改'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(diaryNotifier.saves, isEmpty);
      expect(find.text('open'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('选「保存」写库一次后退出，返回状态转已保存', (tester) async {
      await openEditor(tester);
      await editContent(tester, '要留下');
      await pressBack(tester);

      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(diaryNotifier.saves, hasLength(1));
      expect(diaryNotifier.saves.single.content, '要留下');
      expect(find.text('open'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('写库失败时停在编辑页并给出可重试提示', (tester) async {
      await openEditor(tester, failUpdate: true);
      await editContent(tester, '存不下的内容');
      await pressBack(tester);

      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(diaryNotifier.saves, hasLength(1));
      // 关键：失败不许假装保存成功而退出
      expect(find.byType(DiaryEditorView), findsOneWidget);
      expect(find.text('open'), findsNothing);
      expect(find.textContaining('未能保存'), findsOneWidget);
      expect(find.text('未保存'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('直接点「保存修改」按钮：写库一次并退出', (tester) async {
      await openEditor(tester);
      await editContent(tester, '走按钮保存');

      await tester.tap(find.widgetWithText(FilledButton, '保存修改'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(diaryNotifier.saves, hasLength(1));
      expect(diaryNotifier.saves.single.content, '走按钮保存');
      expect(find.text('open'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('按钮路径写库失败时不退出并给出可重试提示', (tester) async {
      await openEditor(tester, failUpdate: true);
      await editContent(tester, '按钮也存不下');

      await tester.tap(find.widgetWithText(FilledButton, '保存修改'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DiaryEditorView), findsOneWidget);
      expect(find.textContaining('保存失败，内容未存储'), findsOneWidget);

      await drainTimers(tester);
    });
  });
}
