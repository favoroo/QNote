import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
import 'package:qnote_flutter/providers/quick_prompt_provider.dart';
import 'package:qnote_flutter/widgets/ai/quick_prompt_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 常用提示词弹窗的技能勾选链路。
///
/// 坑位记录（同 q_voice_page_test）：testWidgets 跑在 FakeAsync 区，弹窗
/// initState 里的 `SkillRegistry.ensureLoaded()` 与使用统计读库都会碰真实 IO。
/// 因此在 setUpAll（真实异步区）先建库并预热技能缓存与统计缓存，widget 内只剩
/// 已完成的 Future，pump 才能把弹窗推完。
class _FakeQuickPromptNotifier extends QuickPromptNotifier {
  @override
  Future<List<String>> build() async => ['总结今天', '写一份周报'];
}

/// 打开弹窗的宿主页：把回调结果收进 [selected]，避免测试去读页面内部状态
class _DialogHost extends ConsumerWidget {
  const _DialogHost({required this.onSelected, this.initialSkillNames = const [], this.onSkillsChanged});

  final void Function(QuickPromptSelection selection) onSelected;
  final List<String> initialSkillNames;
  final void Function(List<String> skillNames)? onSkillsChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => showQuickPromptDialog(
            context,
            ref,
            onSelected,
            initialSkillNames: initialSkillNames,
            onSkillsChanged: onSkillsChanged,
          ),
          child: const Text('打开'),
        ),
      ),
    );
  }
}

Future<void> _openDialog(
  WidgetTester tester,
  void Function(QuickPromptSelection selection) onSelected, {
  List<String> initialSkillNames = const [],
  void Function(List<String> skillNames)? onSkillsChanged,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [quickPromptListProvider.overrideWith(_FakeQuickPromptNotifier.new)],
      child: MaterialApp(
        home: _DialogHost(
          onSelected: onSelected,
          initialSkillNames: initialSkillNames,
          onSkillsChanged: onSkillsChanged,
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory dbDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbDir = Directory.systemTemp.createTempSync('qnote_quick_prompt_dialog_test');
    await databaseFactoryFfi.setDatabasesPath(dbDir.path);
    await DatabaseHelper.instance.database;
    // 预热技能缓存（含用户技能读取）与使用统计缓存，避免 widget 内触发真实 IO
    await SkillRegistry.instance.ensureLoaded();
    await SkillUsageTracker.instance.record('todo-manager');
  });

  tearDownAll(() {
    // DatabaseHelper 没有关库入口，unlink 后连接仍指向该 inode，进程退出即回收
    try {
      dbDir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响测试结论
    }
  });

  testWidgets('勾选技能后选提示词，回调同时带回提示词与技能名', (tester) async {
    QuickPromptSelection? selected;
    await _openDialog(tester, (selection) => selected = selection);

    expect(find.text('附加技能'), findsOneWidget);
    expect(find.text('todo-manager'), findsOneWidget);
    expect(find.text('总结今天'), findsOneWidget);

    await tester.tap(find.text('todo-manager'));
    await tester.pump();
    // 选中态切换为对勾（未选中时是 auto_awesome 轮廓图标）
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('todo-manager'), matching: find.byType(Material)),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsWidgets,
    );

    await tester.tap(find.text('总结今天'));
    await tester.pumpAndSettle();

    expect(selected, isNotNull);
    expect(selected!.text, '总结今天');
    expect(selected!.skillNames, ['todo-manager']);
  });

  testWidgets('重新打开时保持已选技能，取消勾选后返回空列表', (tester) async {
    QuickPromptSelection? selected;
    final changes = <List<String>>[];
    await _openDialog(
      tester,
      (selection) => selected = selection,
      initialSkillNames: ['todo-manager', 'mermaid-diagram'],
      onSkillsChanged: changes.add,
    );

    // 已选技能整体排在前面，长列表里也能直接看到勾选状态
    expect(find.text('todo-manager'), findsOneWidget);
    expect(find.text('mermaid-diagram'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));

    await tester.tap(find.text('todo-manager'));
    await tester.pump();
    expect(changes.last, ['mermaid-diagram'], reason: '取消勾选即时同步给输入区');
    await tester.tap(find.text('写一份周报'));
    await tester.pumpAndSettle();

    expect(selected!.skillNames, ['mermaid-diagram']);
  });

  testWidgets('只勾技能、不选提示词直接关闭，选择仍同步到输入区', (tester) async {
    final changes = <List<String>>[];
    await _openDialog(tester, (_) {}, onSkillsChanged: changes.add);

    await tester.tap(find.text('todo-manager'));
    await tester.pump();
    expect(changes.last, ['todo-manager']);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.text('附加技能'), findsNothing, reason: '弹窗应已关闭');
    expect(changes.last, ['todo-manager'], reason: '关闭不应回滚已勾选的技能');
  });

  testWidgets('不勾选技能时按普通提示词返回空技能列表', (tester) async {
    QuickPromptSelection? selected;
    await _openDialog(tester, (selection) => selected = selection);

    await tester.tap(find.text('写一份周报'));
    await tester.pumpAndSettle();

    expect(selected!.text, '写一份周报');
    expect(selected!.skillNames, isEmpty);
  });

  testWidgets('小屏横屏下技能分组不撑破弹窗', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester, (_) {});

    expect(tester.takeException(), isNull, reason: '矮屏下技能展开区应自适应收缩，不能溢出');
    expect(find.text('附加技能'), findsOneWidget);
    expect(find.text('内置技能'), findsOneWidget);
    expect(find.text('todo-manager'), findsOneWidget);
  });

  testWidgets('自定义技能与内置技能分组展示，折叠展开互斥', (tester) async {
    // 用户技能需要写库，放到真实异步区执行；技能缓存会同步更新，弹窗读缓存即可
    await tester.runAsync(() async {
      await SkillRegistry.instance.saveUserSkill(
        AgentSkill(name: 'my-review', description: '我的复盘技能', content: '# 我的复盘'),
      );
    });
    try {
      await _openDialog(tester, (_) {});

      expect(find.text('自定义技能'), findsOneWidget);
      expect(find.text('内置技能'), findsOneWidget);
      // 默认展开自定义组（含刚建的技能），内置组收起
      expect(find.text('my-review'), findsOneWidget);
      expect(find.text('todo-manager'), findsNothing);

      // 展开内置组：自定义组自动收起，两组不会同时铺开
      await tester.tap(find.text('内置技能'));
      await tester.pumpAndSettle();
      expect(find.text('todo-manager'), findsOneWidget);
      expect(find.text('my-review'), findsNothing);

      // 切回自定义组
      await tester.tap(find.text('自定义技能'));
      await tester.pumpAndSettle();
      expect(find.text('my-review'), findsOneWidget);
      expect(find.text('todo-manager'), findsNothing);
    } finally {
      await tester.runAsync(() => SkillRegistry.instance.deleteUserSkill('my-review'));
    }
  });
}
