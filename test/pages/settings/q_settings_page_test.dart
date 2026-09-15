import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/pages/settings/q_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.instance.database;
  });

  testWidgets('QSettingsPage renders tabs and switches between them', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QSettingsPage(),
        ),
      ),
    );
    await tester.pump();

    // 等待异步加载完成
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // 默认展示「小Q设置」AppBar 以及三个分段标签
    expect(find.text('小Q设置'), findsOneWidget);
    expect(find.text('个性'), findsOneWidget);
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);

    // 初始处于「个性」Tab，渲染预设个性卡片
    expect(find.text('经典管家'), findsOneWidget);
    expect(find.textContaining('沉稳可靠的全能终端管家'), findsOneWidget);

    // 点击切换到「技能」Tab
    await tester.tap(find.text('技能'));
    await tester.pump();

    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // 技能 Tab 下 AppBar 显示「新建技能」加号按钮
    expect(find.byIcon(Icons.add), findsOneWidget);

    // 点击切换到「记忆」Tab
    await tester.tap(find.text('记忆'));
    await tester.pump();
  });
}
