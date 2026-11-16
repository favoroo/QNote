import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/pages/settings/q_knowledge_page.dart';
import 'package:qnote_flutter/providers/knowledge_graph_provider.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.overrideDatabasePath(inMemoryDatabasePath);
    await DatabaseHelper.instance.database;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('320pt 下展示手动更新入口、待整理数量与高级操作', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kgStatusProvider.overrideWith(
            (ref) async => {
              'document_count': 12,
              'has_source_data': true,
              'pending_rule_count': 3,
              'entity_count': 8,
              'state_count': 2,
              'edge_count': 20,
              'mention_count': 40,
              'last_scan_at': '2026-11-16T10:00:00.000',
              'semantic_docs_today': 2,
              'semantic_limit': 30,
            },
          ),
        ],
        child: const MaterialApp(home: QKnowledgePage()),
      ),
    );
    // 配置读取与状态 Provider 都是真实异步，逐轮给微任务留时间；
    // 不能用 pumpAndSettle（加载中的进度指示器会一直动画）。
    for (var i = 0; i < 20 && find.textContaining('约 3 条').evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }

    expect(find.text('更新图谱'), findsOneWidget);
    expect(find.text('深度分析笔记'), findsOneWidget);
    expect(find.textContaining('约 3 条'), findsOneWidget);
    expect(find.textContaining('2/30 篇'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('高级操作'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    expect(find.text('高级操作'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
