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

AiProviderModel _model(String id, {ReasoningEffort? effort}) =>
    AiProviderModel.of(id, reasoningEffort: effort);

AiRouteGroup _group({
  required List<RouteGroupMember> members,
  RouteStrategy strategy = RouteStrategy.rotate,
}) => AiRouteGroup(
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
  AiModelRef? selected,
  Future<bool> Function(AiModelRef ref)? onSelect,
  Future<bool> Function(
    List<ReasoningEffortTarget> targets,
    ReasoningEffort? effort,
  )?
  onEffort,
}) async {
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
                onSelectBinding: onSelect ?? (ref) async => true,
                onEffortChanged: onEffort ?? (targets, effort) async => true,
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
  final primary = _provider(
    id: 'p1',
    name: '主力',
    models: [_model('gpt-5.4-mini'), _model('gpt-5.4')],
    isDefault: true,
  );
  final backup = _provider(id: 'p2', name: '备用', models: [_model('glm-4.6')]);

  group('思考强度作用对象', () {
    test('具体模型就是它自己', () {
      final targets = reasoningTargetsOf(
        const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
        [primary, backup],
        const [],
      );
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
          RouteGroupMember(
            providerId: 'p1',
            modelName: 'gpt-5.4',
            enabled: false,
          ),
        ],
      );
      final targets = reasoningTargetsOf(
        AiModelRef.routeGroup('g1'),
        [primary, backup],
        [group],
      );
      expect(targets.map((t) => '${t.provider.id}/${t.model.id}'), [
        'p1/gpt-5.4-mini',
        'p2/glm-4.6',
      ]);
    });

    test('绑定失效或为空时没有作用对象', () {
      expect(reasoningTargetsOf(null, [primary], const []), isEmpty);
      expect(
        reasoningTargetsOf(const AiModelRef(providerId: 'p9', modelName: 'x'), [
          primary,
        ], const []),
        isEmpty,
      );
    });

    test('同一档位给出单值，档位不一致标记混合', () {
      final same = reasoningEffortStateOf(
        reasoningTargetsOf(
          const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
          [primary],
          const [],
        ),
      );
      expect(same?.effort, isNull);
      expect(same?.mixed, isFalse);
      expect(same?.capability.supports(ReasoningEffort.none), isTrue);

      final mixed = reasoningEffortStateOf([
        (provider: primary, model: _model('gpt-5.4-mini')),
        (
          provider: backup,
          model: _model('glm-4.6', effort: ReasoningEffort.high),
        ),
      ]);
      expect(mixed?.mixed, isTrue);
    });
  });

  group('选择面板', () {
    testWidgets('一级列厂商与路由组，当前绑定打勾', (tester) async {
      await _openSheet(
        tester,
        providers: [primary, backup],
        groups: [
          _group(
            members: const [
              RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4-mini'),
            ],
          ),
        ],
        selected: const AiModelRef(providerId: 'p1', modelName: 'gpt-5.4-mini'),
      );

      expect(find.text('路由组'), findsOneWidget);
      expect(find.text('厂商'), findsOneWidget);
      expect(find.text('故障转移组'), findsOneWidget);
      expect(find.text('主力'), findsOneWidget);
      expect(find.text('备用'), findsOneWidget);
      expect(find.text('当前 gpt-5.4-mini · 默认'), findsOneWidget);
      // 只有当前绑定的厂商行打勾
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('点厂商进入二级：模型与思考强度同屏，点模型即写库', (tester) async {
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

      await tester.tap(find.text('主力'));
      await tester.pumpAndSettle();

      expect(find.text('上一步'), findsOneWidget);
      expect(find.text('模型'), findsOneWidget);
      expect(find.text('思考强度'), findsOneWidget);
      // 当前绑定在备用，主力面板先用文字说明「选中模型后」才能调
      expect(find.text('选中模型后即可调整它的思考强度'), findsOneWidget);

      await tester.tap(find.text('gpt-5.4-mini'));
      await tester.pumpAndSettle();

      expect(selections.single.providerId, 'p1');
      expect(selections.single.modelName, 'gpt-5.4-mini');
      // 面板保持打开，勾选与思考强度都跟到新模型上
      expect(find.text('思考强度'), findsOneWidget);
      expect(find.text('选中模型后即可调整它的思考强度'), findsNothing);
      expect(_chipSelected(tester, '自动'), isTrue);

      // 返回一级后勾选也跟着移动
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(find.text('当前 gpt-5.4-mini · 默认'), findsOneWidget);
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
          bound = AiModelRef(
            providerId: targets.single.provider.id,
            modelName: targets.single.model.id,
          );
          return true;
        },
      );

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

      await tester.tap(find.text('主力'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      expect(_chipSelected(tester, '高'), isFalse);
      expect(_chipSelected(tester, '自动'), isTrue);
    });

    testWidgets('思考强度对不支持关闭的模型只给低中高', (tester) async {
      final oSeries = _provider(
        id: 'p3',
        name: '推理',
        models: [_model('o3-mini')],
      );
      await _openSheet(
        tester,
        providers: [oSeries],
        selected: const AiModelRef(providerId: 'p3', modelName: 'o3-mini'),
      );

      await tester.tap(find.text('推理'));
      await tester.pumpAndSettle();

      expect(_chipSelected(tester, '自动'), isTrue);
      expect(find.widgetWithText(ChoiceChip, '关闭'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '低'), findsOneWidget);
    });

    testWidgets('路由组二级列成员，档位作用于全部启用成员', (tester) async {
      final group = _group(
        strategy: RouteStrategy.failover,
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4-mini'),
          RouteGroupMember(providerId: 'p2', modelName: 'glm-4.6'),
          RouteGroupMember(
            providerId: 'p1',
            modelName: 'gpt-5.4',
            enabled: false,
          ),
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

      expect(find.text('组内模型'), findsOneWidget);
      expect(find.text('按「顺序」自动选择'), findsOneWidget);
      // 组内停用的成员也列出来，但要标出来
      expect(find.text('gpt-5.4'), findsOneWidget);
      expect(find.textContaining('组内已停用'), findsOneWidget);

      // 档位按首个成员（gpt-5.4-mini）的能力给，组内其他成员不支持的档位由发信层跳过
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      expect(targets?.map((t) => t.model.id), ['gpt-5.4-mini', 'glm-4.6']);
    });
  });
}
