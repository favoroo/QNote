import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/storage/ai_provider_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/pages/settings/q_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 逐轮给真实异步（sqflite 厂商、路由组、Token 聚合）留时间，直到 [done] 成立。
///
/// 小Q设置默认停在「模型」分段，一帧之内读不完这些库，单次 runAsync 只够跑完
/// 第一批查询；这里按轮推进，避免测试卡在「库还没回来」的中间态上。
Future<void> _settleUntil(WidgetTester tester, bool Function() done, {int maxRounds = 20}) async {
  for (var i = 0; i < maxRounds && !done(); i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }
  // 收尾再排空一轮，避免 IndexedStack 里不可见分段的查询留下 pending timer
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
}

Future<void> _pumpQSettings(WidgetTester tester, {int initialTab = 0}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: QSettingsPage(initialTab: initialTab)),
    ),
  );
  await tester.pump();
  await _settleUntil(tester, () => false, maxRounds: 4);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.instance.database;
    // 预置一条模型服务：有数据时「模型服务」区块标题与右侧圆形「+」才会渲染，
    // 否则走的是 NoModelGuideCard 空态（另有整卡「去添加模型」入口）
    await AiProviderRepository.instance.upsert(
      AiProvider(
        id: 'test-provider',
        name: '测试服务',
        providerType: 'openai',
        baseUrl: 'https://example.com/v1',
        apiKeys: const ['sk-test'],
        models: const [AiProviderModel(id: 'test-model', name: 'test-model')],
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    );
  });

  testWidgets('五个分段齐全，默认停在模型分段并可来回切换', (tester) async {
    await _pumpQSettings(tester);

    // 默认展示「小Q设置」AppBar 以及五个分段标签
    expect(find.text('小Q设置'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(find.text('个性'), findsOneWidget);
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('语音'), findsOneWidget);

    // 默认停在「模型」分段：原 AI 模型配置整页已嵌入，添加入口在「模型服务」标题右侧
    await _settleUntil(tester, () => find.text('模型服务').evaluate().isNotEmpty);
    expect(find.text('模型服务'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_rounded)).tooltip, '添加模型服务');
    // 顶栏不再为模型段提供「+」
    expect(find.widgetWithIcon(IconButton, Icons.add), findsNothing);

    // 顶部新增了「小Q 内置服务」卡片，模型分配区块要滚动进视口才会被 ListView 构建
    await tester.scrollUntilVisible(find.text('模型分配'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('模型分配'), findsOneWidget);
    // 回到顶部，后面的模型服务断言仍可见
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 500));
    await tester.pump();

    // 切到「个性」：渲染预设个性卡片
    await tester.tap(find.text('个性'));
    await tester.pump();
    await _settleUntil(tester, () => find.text('经典管家').evaluate().isNotEmpty);

    expect(find.text('经典管家'), findsAtLeastNWidgets(1));
    expect(find.textContaining('沉稳可靠的全能终端管家'), findsOneWidget);

    // 切到「技能」：顶栏换成新建技能
    await tester.tap(find.text('技能'));
    await tester.pump();
    await _settleUntil(tester, () => find.text('用户技能').evaluate().isNotEmpty);

    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add)).tooltip, '新建技能');

    // 切回「模型」：顶栏的「+」撤掉，添加入口回到「模型服务」标题右侧
    await tester.tap(find.text('模型'));
    await tester.pump();
    await _settleUntil(tester, () => find.text('模型服务').evaluate().isNotEmpty, maxRounds: 6);

    expect(find.widgetWithIcon(IconButton, Icons.add), findsNothing);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_rounded)).tooltip, '添加模型服务');
  });

  testWidgets('initialTab 可直接定位到指定分段', (tester) async {
    // 1 = 个性；模型分段仍在 IndexedStack 里但不可见
    await _pumpQSettings(tester, initialTab: 1);
    await _settleUntil(tester, () => find.text('经典管家').evaluate().isNotEmpty);

    expect(find.textContaining('沉稳可靠的全能终端管家'), findsOneWidget);
  });
}
