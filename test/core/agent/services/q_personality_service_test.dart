import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/pages/settings/q_personality_page.dart';
import 'package:qnote_flutter/providers/agent_support.dart';

/// 小Q个性配置的读取契约与设置页回显
///
/// 这里锁的是用户报过的一类现象：「性格改了却不生效」。历史实现带内存缓存，
/// 而 WebDAV 同步与备份恢复是绕过 service 直接写 app_configs 的，缓存不刷新就继续用旧人格；
/// 另外 custom 个性在描述为空时会静默回退经典管家，界面上完全看不出来。
/// 现在配置改为直读存储，设置页顶部卡片显式回显「运行时真正注入的那段人格」。
void main() {
  late Database db;
  final service = QPersonalityService.instance;
  final repo = ConfigRepository.instance;
  String? originalConfig;

  Future<void> seedConfig(Map<String, dynamic> config) async {
    await repo.setAppConfig(QPersonalityService.storageKey, jsonEncode(config));
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
    originalConfig = await repo.getAppConfig(QPersonalityService.storageKey);
  });

  setUp(() async {
    await seedConfig({
      'activeId': QPersonalities.defaultId,
      'customPrompt': '',
    });
  });

  tearDown(() async {
    if (originalConfig == null) {
      await db.delete(
        'app_configs',
        where: 'key = ?',
        whereArgs: [QPersonalityService.storageKey],
      );
    } else {
      await repo.setAppConfig(
        QPersonalityService.storageKey,
        originalConfig!,
      );
    }
  });

  group('QPersonalityService 直读存储', () {
    test('外部直接写库（同步/恢复路径）后立刻读到新个性，不受缓存影响', () async {
      expect(
        (await service.getActivePersonality()).id,
        QPersonalities.defaultId,
      );

      // 模拟 export_service 的 app_configs 分支：绕过 service 直接落库
      await repo.setAppConfig(
        QPersonalityService.storageKey,
        jsonEncode({'activeId': 'gentle', 'customPrompt': ''}),
      );

      final active = await service.getActivePersonality();
      expect(active.id, 'gentle');
      expect(active.name, '温柔陪伴');
      expect(active.digest, contains('接住情绪'));
    });

    test('custom 且描述为空时回退经典管家，而不是拼出无人格的提示词', () async {
      await seedConfig({
        'activeId': QPersonalities.customId,
        'customPrompt': '   ',
      });
      final active = await service.getActivePersonality();
      expect(active.id, QPersonalities.defaultId);
      expect(active.prompt, isNotEmpty);
      expect(active.digest, isNotEmpty);
    });

    test('custom 有描述时以用户文本为 prompt，digest 取首句', () async {
      await seedConfig({
        'activeId': QPersonalities.customId,
        'customPrompt': '你是毒舌但护短的搭档。\n不许说客套话。',
      });
      final active = await service.getActivePersonality();
      expect(active.id, QPersonalities.customId);
      expect(active.name, '自定义');
      expect(active.prompt, '你是毒舌但护短的搭档。\n不许说客套话。');
      expect(active.digest, '你是毒舌但护短的搭档。');
    });

    test('VFS 写入通道只接受合法 activeId，未知值不覆盖当前个性', () async {
      await seedConfig({'activeId': 'concise', 'customPrompt': ''});
      await service.applyPartialConfig({'activeId': 'not-a-personality'});
      expect(await service.getActiveId(), 'concise');

      await service.applyPartialConfig({'activeId': 'energetic'});
      expect(await service.getActiveId(), 'energetic');
    });

    test('setActiveId 拒绝未知标识', () async {
      expect(() => service.setActiveId('unknown'), throwsA(isA<Exception>()));
    });
  });

  group('快照的回退判定', () {
    test('custom 且描述为空时 degradedToFallback 为真，补全描述后转假', () async {
      await seedConfig({
        'activeId': QPersonalities.customId,
        'customPrompt': '',
      });
      var snapshot = await service.readSnapshot();
      expect(snapshot.selectedId, QPersonalities.customId);
      expect(snapshot.effective.id, QPersonalities.defaultId);
      expect(
        snapshot.degradedToFallback,
        isTrue,
        reason: '设置页据此提示「实际仍按经典管家说话」，静默回退必须可被界面察觉',
      );

      await seedConfig({
        'activeId': QPersonalities.customId,
        'customPrompt': '说话像老朋友。',
      });
      snapshot = await service.readSnapshot();
      expect(snapshot.degradedToFallback, isFalse);
      expect(snapshot.effective.id, QPersonalities.customId);
      expect(snapshot.customPrompt, '说话像老朋友。');
    });

    test('预设个性下不误报降级，自定义文本仍留在存储里', () async {
      await seedConfig({'activeId': 'energetic', 'customPrompt': '残留文本'});
      final snapshot = await service.readSnapshot();
      expect(snapshot.selectedId, 'energetic');
      expect(snapshot.effective.name, '活泼元气');
      expect(snapshot.degradedToFallback, isFalse);
      // 切回 custom 时这段文本还能直接用，不该被预设覆盖掉
      expect(snapshot.customPrompt, '残留文本');
    });
  });

  group('系统提示词尾部人格复述', () {
    test('人格摘要作为环境上下文的最后一行，且不影响无人格时的输出', () async {
      final withPersonality = await buildBaseDynamicContext(
        personality: QPersonalities.byId('energetic'),
        extraSections: const ['页面上下文：日记页'],
      );
      final lastLine = const LineSplitter().convert(withPersonality).last;
      expect(lastLine, startsWith('- 你的个性「活泼元气」'));
      expect(lastLine, contains('颜文字'));
      expect(
        lastLine,
        contains('优先于系统提示词里所有关于简洁与格式的条款'),
        reason: '这行的作用就是给语气拿到最终话语权，措辞改掉就失去意义',
      );
      // 排在 extraSections 之后：越贴近用户消息，抗稀释效果越好
      expect(withPersonality.indexOf('页面上下文：日记页'), lessThan(
        withPersonality.indexOf('你的个性「活泼元气」'),
      ));

      final withoutPersonality = await buildBaseDynamicContext();
      expect(withoutPersonality, isNot(contains('你的个性')));
    });

    test('自定义人格的摘要同样进入尾部复述', () async {
      await seedConfig({
        'activeId': QPersonalities.customId,
        'customPrompt': '像一位耐心的老编辑：先肯定，再动笔。',
      });
      final personality = await service.getActivePersonality();
      final context = await buildBaseDynamicContext(personality: personality);
      expect(
        const LineSplitter().convert(context).last,
        '- 你的个性「自定义」—— 像一位耐心的老编辑：先肯定，再动笔。；'
            '这条语气要求优先于系统提示词里所有关于简洁与格式的条款，'
            '也优先于你在本次会话前几轮里的措辞习惯，但不得因此改动数据真实性与操作规范。',
      );
    });
  });

  group('设置页「当前生效」卡片', () {
    // testWidgets 主体跑在 FakeAsync 区块里，任何真实的 sqflite future（含本测试自己的
    // 配置写入、页面 initState 的读取）都必须放进 tester.runAsync 窗口，否则永远等不到
    Future<void> pumpPage(
      WidgetTester tester,
      Map<String, dynamic> config,
    ) async {
      await tester.runAsync(() => seedConfig(config));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: QPersonalityPage(embedded: true)),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '配置还没读完，后面的断言都会失真',
      );
    }

    testWidgets('回显真实生效个性的名称与注入文本', (tester) async {
      await pumpPage(tester, {'activeId': 'energetic', 'customPrompt': ''});

      expect(find.text('当前生效个性'), findsOneWidget);
      expect(find.text('活泼元气'), findsWidgets);
      expect(find.textContaining('元气小Q'), findsOneWidget);
      expect(find.textContaining('自定义人格描述还是空的'), findsNothing);
    });

    testWidgets('自定义描述为空时显式提示实际回退到经典管家', (tester) async {
      await pumpPage(tester, {
        'activeId': QPersonalities.customId,
        'customPrompt': '',
      });

      expect(
        find.textContaining('自定义人格描述还是空的'),
        findsOneWidget,
        reason: '静默回退必须在界面上可见，否则用户只会觉得「设置没生效」',
      );
      expect(find.text('经典管家'), findsWidgets);
    });

    testWidgets('自定义有内容时展示人格文本与结尾复述句预览', (tester) async {
      await pumpPage(tester, {
        'activeId': QPersonalities.customId,
        'customPrompt': '你是毒舌但护短的搭档。不许说客套话。',
      });

      expect(find.textContaining('自定义人格描述还是空的'), findsNothing);
      expect(find.textContaining('毒舌但护短'), findsWidgets);
      expect(
        find.textContaining('结尾复述句：你是毒舌但护短的搭档。'),
        findsOneWidget,
      );
    });
  });
}
