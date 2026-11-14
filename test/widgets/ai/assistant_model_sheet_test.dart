import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/widgets/ai/assistant_model_sheet.dart';

AiProvider _provider({
  required String id,
  required String name,
  required List<AiProviderModel> models,
  bool isDefault = false,
}) => AiProvider(
  id: id,
  vendorId: 'custom',
  name: name,
  providerType: 'openai',
  baseUrl: 'https://example.com/v1',
  apiKeys: const ['sk-test'],
  models: models,
  isDefault: isDefault,
  enabled: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

AiProviderModel _model(String id, {ReasoningEffort? effort, List<ReasoningEffort>? efforts}) =>
    AiProviderModel.of(id, reasoningEffort: effort, reasoningEfforts: efforts);

AiRouteGroup _group({required List<RouteGroupMember> members, RouteStrategy strategy = RouteStrategy.rotate}) =>
    AiRouteGroup(
      id: 'g1',
      name: '故障转移组',
      strategy: strategy,
      members: members,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 打开面板并稳定到空闲状态（弹层有进场动画，需要落定）
Future<void> _openSheet(
  WidgetTester tester, {
  required List<AiProvider> providers,
  List<AiRouteGroup> groups = const [],
  List<AiModelRef> recent = const [],
  AiModelRef? selected,
  Future<bool> Function(AiModelRef ref)? onSelect,
  Future<bool> Function(List<ReasoningEffortTarget> targets, ReasoningEffort? effort)? onEffort,
  Future<bool> Function(ReasoningEffortTarget target, List<ReasoningEffort>? levels)? onLevels,
}) async {
  // 面板底部常驻思考强度区块，默认 800x600 的测试视口装不下完整列表
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showAssistantModelSheet(
                context,
                providers: providers,
                groups: groups,
                selected: selected,
                recentModels: recent,
                onSelectBinding: onSelect ?? (ref) async => true,
                onEffortChanged: onEffort ?? (targets, effort) async => true,
                onLevelsChanged: onLevels,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 某个档位 chip 是否被选中
bool _chipSelected(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

void main() {
  final primary = _provider(id: 'p1', name: '主力', models: [_model('gpt-5.4-mini'), _model('gpt-5.4')], isDefault: true);
  final backup = _provider(id: 'p2', name: '备用', models: [_model('glm-4.6')]);

  group('思考强度作用对象', () {
    test('具体模型就是它自己', () {
      final targets = reasoningTargetsOf(const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'), [
        primary,
        backup,
      ], const []);
      expect(targets, hasLength(1));
      expect(targets.first.provider.id, 'p1');
      expect(targets.first.model.id, 'gpt-5.4-mini');
    });

    test('路由组展开为全部启用成员，跳过失效成员', () {
      final group = _group(
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4-mini'),
          RouteGroupMember(providerId: 'p2', modelName: 'glm-4.6'),
          RouteGroupMember(providerId: 'p2', modelName: '已删除的模型'),
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4', enabled: false),
        ],
      );
      final targets = reasoningTargetsOf(AiModelRef.routeGroup('g1'), [primary, backup], [group]);
      expect(targets.map((t) => '${t.provider.id}/${t.model.id}'), ['p1/gpt-5.4-mini', 'p2/glm-4.6']);
    });

    test('绑定失效或为空时没有作用对象', () {
      expect(reasoningTargetsOf(null, [primary], const []), isEmpty);
      expect(reasoningTargetsOf(const AiModelRef(providerId: 'p9', modelName: 'x'), [primary], const []), isEmpty);
    });

    test('同一档位给出单值，档位不一致标记混合', () {
      final same = reasoningEffortStateOf(
        reasoningTargetsOf(const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'), [primary], const []),
      );
      expect(same?.effort, isNull);
      expect(same?.mixed, isFalse);
      expect(same?.capability.supports(ReasoningEffort.none), isTrue);

      final mixed = reasoningEffortStateOf([
        (provider: primary, model: _model('gpt-5.4-mini')),
        (provider: backup, model: _model('glm-4.6', effort: ReasoningEffort.high)),
      ]);
      expect(mixed?.mixed, isTrue);
    });

    test('自定义档位覆盖自动识别，裁掉当前档位后按自动处理', () {
      final custom = _model(
        'gpt-5.4-mini',
        effort: ReasoningEffort.xhigh,
        efforts: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
      );
      final state = reasoningEffortStateOf([(provider: primary, model: custom)]);
      expect(state?.capability.levels, [ReasoningEffort.minimal, ReasoningEffort.xhigh]);
      expect(state?.effort, ReasoningEffort.xhigh);

      // 当前存的是高，但自定义集合里没有高：发信层不会发，界面按自动显示
      final stale = _model(
        'gpt-5.4-mini',
        effort: ReasoningEffort.high,
        efforts: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
      );
      final staleState = reasoningEffortStateOf([(provider: primary, model: stale)]);
      expect(staleState?.effort, isNull);
    });
  });

  group('选择面板', () {
    testWidgets('一级直接列模型与路由组，当前绑定打勾', (tester) async {
      await _openSheet(
        tester,
        providers: [primary, backup],
        groups: [
          _group(
            members: const [RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4-mini')],
          ),
        ],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
      );

      // 切换模型的主路径是看到模型名直接点：厂商不再占据一级
      expect(find.text('路由组'), findsOneWidget);
      expect(find.text('故障转移组'), findsOneWidget);
      expect(find.text('全部模型'), findsOneWidget);
      expect(find.text('按厂商浏览（2）'), findsOneWidget);
      expect(find.text('厂商'), findsNothing);
      // 一级模型行标题是模型名，副标题才写厂商
      expect(find.widgetWithText(ListTile, 'gpt-5.4-mini'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'glm-4.6'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'gpt-5.4'), findsOneWidget);
      // 只有当前绑定的模型行打勾
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      // 一级常驻思考强度：当前模型与档位都直接可见
      expect(find.text('当前模型'), findsOneWidget);
      expect(_chipSelected(tester, '自动'), isTrue);
    });

    testWidgets('最近使用置顶，且不在下方重复列出', (tester) async {
      await _openSheet(
        tester,
        providers: [primary, backup],
        recent: const [AiModelRef(providerId: 'p2', modelName: 'glm-4.6')],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
      );

      expect(find.text('最近使用'), findsOneWidget);
      // 最近使用里出现过的模型不再在「全部模型」重复列出
      expect(find.widgetWithText(ListTile, 'glm-4.6'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'gpt-5.4-mini'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'gpt-5.4'), findsOneWidget);
      // 最近使用行在「全部模型」之上
      expect(tester.getTopLeft(find.text('最近使用')).dy, lessThan(tester.getTopLeft(find.text('全部模型')).dy));

      await tester.tap(find.widgetWithText(ListTile, 'glm-4.6'));
      await tester.pumpAndSettle();
      expect(_chipSelected(tester, '自动'), isTrue);
    });

    testWidgets('最近使用里已失效的引用不显示', (tester) async {
      await _openSheet(
        tester,
        providers: [primary],
        recent: const [AiModelRef(providerId: 'p9', modelName: '已删除')],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
      );

      expect(find.text('最近使用'), findsNothing);
      expect(find.text('全部模型'), findsOneWidget);
    });

    testWidgets('一级直接调当前模型的思考强度，不用进二级', (tester) async {
      ReasoningEffort? written;
      await _openSheet(
        tester,
        providers: [primary, backup],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        onEffort: (targets, effort) async {
          written = effort;
          return true;
        },
      );

      await tester.tap(find.text('中'));
      await tester.pumpAndSettle();

      expect(written, ReasoningEffort.medium);
      expect(_chipSelected(tester, '中'), isTrue);
      // 仍停在一级：没有「上一步」，当前模型行还在
      expect(find.text('上一步'), findsNothing);
      expect(find.text('当前模型'), findsOneWidget);
    });

    testWidgets('对话面板只展示模型自定义的档位', (tester) async {
      final custom = _provider(
        id: 'p4',
        name: '自定义',
        models: [
          _model(
            'gpt-5.4-mini',
            effort: ReasoningEffort.xhigh,
            efforts: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
          ),
        ],
      );
      await _openSheet(
        tester,
        providers: [custom],
        selected: const AiModelRef(providerId: 'p4', modelName: 'gpt-5.4-mini'),
      );

      expect(find.widgetWithText(ChoiceChip, '最少'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '极高'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '低'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '中'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '高'), findsNothing);
      expect(_chipSelected(tester, '极高'), isTrue);
    });

    testWidgets('按厂商浏览：厂商列表 → 该厂商模型，点模型即写库', (tester) async {
      final selections = <AiModelRef>[];
      await _openSheet(
        tester,
        providers: [primary, backup],
        selected: const AiModelRef(providerId: 'p2', modelName: 'glm-4.6'),
        onSelect: (ref) async {
          selections.add(ref);
          return true;
        },
      );

      await tester.tap(find.text('按厂商浏览（2）'));
      await tester.pumpAndSettle();

      expect(find.text('按厂商选择'), findsOneWidget);
      expect(find.text('上一步'), findsOneWidget);
      // 当前绑定在备用，主力行用文案说明「这家现在用的是谁」
      expect(find.text('主力'), findsOneWidget);
      expect(find.text('2 个模型 · 默认'), findsOneWidget);
      expect(find.text('当前 glm-4.6'), findsOneWidget);

      await tester.tap(find.text('主力'));
      await tester.pumpAndSettle();

      expect(find.text('思考强度'), findsOneWidget);
      // 当前绑定在备用，主力面板先用文字说明「选中模型后」才能调
      expect(find.text('选中模型后即可调整它的思考强度'), findsOneWidget);

      await tester.tap(find.text('gpt-5.4-mini'));
      await tester.pumpAndSettle();

      expect(selections.single.providerId, 'p1');
      expect(selections.single.modelName, 'gpt-5.4-mini');
      // 面板保持打开，思考强度跟到新模型上
      expect(find.text('思考强度'), findsOneWidget);
      expect(find.text('选中模型后即可调整它的思考强度'), findsNothing);
      expect(_chipSelected(tester, '自动'), isTrue);

      // 两次上一步回到一级后勾选也跟着移动
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(find.text('当前模型'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('二级调档写库成功后面板同步显示新档位', (tester) async {
      ReasoningEffort? written;
      AiModelRef? bound;
      await _openSheet(
        tester,
        providers: [primary, backup],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        onEffort: (targets, effort) async {
          written = effort;
          bound = AiModelRef(providerId: targets.single.provider.id, modelName: targets.single.model.id);
          return true;
        },
      );

      await tester.tap(find.text('按厂商浏览（2）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      expect(written, ReasoningEffort.high);
      expect(bound?.modelName, 'gpt-5.4-mini');
      expect(_chipSelected(tester, '高'), isTrue);
      // 标题行也显示当前档位（chip 文案 + 状态文案各一处）
      expect(find.text('高'), findsNWidgets(2));
    });

    testWidgets('写库失败时档位不前进，界面不撒谎', (tester) async {
      await _openSheet(
        tester,
        providers: [primary, backup],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        onEffort: (targets, effort) async => false,
      );

      await tester.tap(find.text('按厂商浏览（2）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      expect(_chipSelected(tester, '高'), isFalse);
      expect(_chipSelected(tester, '自动'), isTrue);
    });

    testWidgets('思考强度对不支持关闭的模型只给低中高', (tester) async {
      final oSeries = _provider(id: 'p3', name: '推理', models: [_model('o3-mini')]);
      await _openSheet(
        tester,
        providers: [oSeries],
        selected: const AiModelRef(providerId: 'p3', modelName: 'o3-mini'),
      );

      expect(_chipSelected(tester, '自动'), isTrue);
      expect(find.widgetWithText(ChoiceChip, '关闭'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '低'), findsOneWidget);
    });

    testWidgets('点路由组即选中，档位作用于全部启用成员', (tester) async {
      final group = _group(
        strategy: RouteStrategy.failover,
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4-mini'),
          RouteGroupMember(providerId: 'p2', modelName: 'glm-4.6'),
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4', enabled: false),
        ],
      );
      List<ReasoningEffortTarget>? targets;
      await _openSheet(
        tester,
        providers: [primary, backup],
        groups: [group],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        onEffort: (value, effort) async {
          targets = value;
          return true;
        },
      );

      await tester.tap(find.text('故障转移组'));
      await tester.pumpAndSettle();

      // 不进二级：没有「上一步」，勾选移到组行，底部说明当前绑定是路由组
      expect(find.text('上一步'), findsNothing);
      expect(find.text('当前路由组'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // 档位按首个成员（gpt-5.4-mini）的能力给，作用对象展开为全部启用成员，
      // 组内其他成员不支持的档位由发信层跳过
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      expect(targets?.map((t) => t.model.id), ['gpt-5.4-mini', 'glm-4.6']);
    });

    testWidgets('底部「管理思考档位」入口直接改当前模型的档位集合', (tester) async {
      List<ReasoningEffort>? written;
      ReasoningEffortTarget? configured;
      await _openSheet(
        tester,
        providers: [primary, backup],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        onLevels: (target, levels) async {
          configured = target;
          written = levels;
          return true;
        },
      );

      await tester.tap(find.text('管理思考档位'));
      await tester.pumpAndSettle();

      expect(find.text('思考档位'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(configured?.model.id, 'gpt-5.4-mini');
      expect(written, ReasoningEffort.values);
      // 写库成功后对话面板立即出现新增档位，不用重开
      expect(find.widgetWithText(ChoiceChip, '极高'), findsOneWidget);
    });

    testWidgets('路由组选中后「管理思考档位」先选成员，再配置该成员的档位', (tester) async {
      final group = _group(
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4-mini'),
          RouteGroupMember(providerId: 'p2', modelName: 'glm-4.6'),
        ],
      );
      String? configured;
      List<ReasoningEffort>? written;
      await _openSheet(
        tester,
        providers: [primary, backup],
        groups: [group],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        onLevels: (target, levels) async {
          configured = target.model.id;
          written = levels;
          return true;
        },
      );

      await tester.tap(find.text('故障转移组'));
      await tester.pumpAndSettle();
      // 绑定到组后底部入口作用于全部成员，先弹成员选择
      await tester.tap(find.textContaining('管理思考档位'));
      await tester.pumpAndSettle();

      expect(find.text('选择要配置档位的模型'), findsOneWidget);
      // 选成员（列表里同时有底层面板的同名模型行）
      await tester.tap(find.text('glm-4.6').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(configured, 'glm-4.6');
      expect(written, ReasoningEffort.values);
    });
  });
}
