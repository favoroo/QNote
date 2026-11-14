import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/services/q_page_context.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/diary/journal_editor_view.dart';

class _NoopFloatingQNotifier extends FloatingQNotifier {
  @override
  void pushOverlayContext(QPageContext context) {}

  @override
  void popOverlayContext(QPageContext context) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dbDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbDir = Directory.systemTemp.createTempSync('qnote_journal_editor_test');
    await databaseFactoryFfi.setDatabasesPath(dbDir.path);
    await DatabaseHelper.instance.database;
  });

  tearDownAll(() {
    try {
      dbDir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响测试结论
    }
  });

  Future<void> pumpJournalEditor(WidgetTester tester, {required DateTime date, required ThemeData theme}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [floatingQProvider.overrideWith(() => _NoopFloatingQNotifier())],
          child: MaterialApp(
            theme: theme,
            home: JournalEditorView(date: date),
          ),
        ),
      );
      // 等待 _loadExisting 完成数据库查询并初始化编辑器
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byType(TextField).evaluate().isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('日期主数字与今天徽标使用主题可读强调色而非 tertiary，且输入框零水平内边距对齐左缘', (tester) async {
    final now = DateTime.now();
    const customAccent = Color(0xFF6B4EFF);
    final theme = AppTheme.lightTheme(customAccent);

    await pumpJournalEditor(tester, date: now, theme: theme);

    final dayStr = now.day.toString().padLeft(2, '0');
    final dayText = tester.widget<Text>(find.text(dayStr));
    expect(dayText.style?.color, theme.accentInk);
    expect(dayText.style?.color, isNot(theme.colorScheme.tertiary));

    final todayText = tester.widget<Text>(find.text('今天'));
    expect(todayText.style?.color, theme.accentInk);

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.decoration?.contentPadding, EdgeInsets.zero);
  });

  testWidgets('派生主题色背景下日期头依然采用校准后的 accentInk 保持可读性', (tester) async {
    final now = DateTime.now();
    const accentColor = Color(0xFF4CAF50);
    final theme = AppTheme.build(
      accentColor: accentColor,
      background: const AppBackgroundSetting(preset: AppBackgroundPreset.accent),
      platformBrightness: Brightness.light,
    );

    await pumpJournalEditor(tester, date: now, theme: theme);

    final dayStr = now.day.toString().padLeft(2, '0');
    final dayText = tester.widget<Text>(find.text(dayStr));
    expect(dayText.style?.color, theme.accentInk);
  });

  testWidgets('右上角不展示保存状态与字数；滚动后顶栏淡入日期标题', (tester) async {
    final date = DateTime(2026, 11, 14);
    final theme = AppTheme.lightTheme(AppTheme.primaryDefault);

    await pumpJournalEditor(tester, date: date, theme: theme);

    // 顶部状态（已保存/未保存/字数）不再出现在顶栏
    expect(find.text('已保存'), findsNothing);
    expect(find.text('未保存'), findsNothing);
    expect(find.text('保存中…'), findsNothing);
    expect(find.textContaining('字'), findsNothing);

    final appBarOpacityFinder = find.descendant(of: find.byType(AppBar), matching: find.byType(AnimatedOpacity));
    final initialOpacity = tester.widget<AnimatedOpacity>(appBarOpacityFinder);
    expect(initialOpacity.opacity, 0.0);

    // 输入内容后依然不出现状态文案，编辑区只保留正文
    final longText = List.generate(30, (i) => '第${i + 1}行日记内容').join('\n');
    await tester.enterText(find.byType(TextField), '$longText   \n');
    await tester.pump();
    expect(find.text('已保存'), findsNothing);
    expect(find.text('未保存'), findsNothing);
    expect(find.textContaining('字'), findsNothing);

    // 向下滚动超过阈值后，顶栏日期标题淡入
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -180));
    await tester.pumpAndSettle();
    final scrolledOpacity = tester.widget<AnimatedOpacity>(appBarOpacityFinder);
    expect(scrolledOpacity.opacity, 1.0);
  });
}
