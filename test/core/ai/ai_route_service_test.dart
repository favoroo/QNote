import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_route_service.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';

import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';

/// 路由组选路逻辑的单元测试（注入 providers/groups，不触库、不联网）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = AiRouteService.instance;
  final now = DateTime(2026, 1, 1);
  var seq = 0;

  AiProvider provider(String id, List<String> models) => AiProvider(
    id: id,
    name: id,
    providerType: 'openai',
    baseUrl: 'https://$id.example.com/v1',
    apiKeys: const ['sk-test-00000000'],
    models: models.map((m) => AiProviderModel.of(m)).toList(),
    createdAt: now,
    updatedAt: now,
  );

  final providers = [
    provider('pA', ['a1', 'a2']),
    provider('pB', ['b1']),
    provider('pC', ['c1']),
  ];

  AiRouteGroup group({
    required RouteStrategy strategy,
    required List<RouteGroupMember> members,
    String? pinnedMember,
    bool preferVision = true,
  }) {
    seq++;
    return AiRouteGroup(
      id: 'g$seq',
      name: 'G$seq',
      strategy: strategy,
      members: members,
      pinnedMember: pinnedMember,
      preferVision: preferVision,
      createdAt: now,
      updatedAt: now,
    );
  }

  RouteGroupMember m(String providerId, String modelName, {int weight = 1}) =>
      RouteGroupMember(providerId: providerId, modelName: modelName, weight: weight);

  setUp(() {
    service.resetForTest();
    ApiKeyPool.instance.resetForTest();
  });

  test('轮流策略按游标推进，跨厂商也按成员顺序换下一个', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pA', 'a1'), m('pB', 'b1'), m('pC', 'c1')]);

    final picks = List.generate(4, (_) => service.select(g, providers).config.modelName);

    expect(picks, ['a1', 'b1', 'c1', 'a1']);
  });

  test('顺序策略始终从第一个可用成员开始，冷却后跳过它', () {
    final g = group(strategy: RouteStrategy.failover, members: [m('pA', 'a1'), m('pB', 'b1'), m('pC', 'c1')]);

    final first = service.select(g, providers).config;
    expect(first.modelName, 'a1');

    // 第一个成员失败进入冷却：下一次选路立即让位给下一个
    service.markMemberFailed(first, Exception('429 rate limit 超限'));

    expect(service.select(g, providers).config.modelName, 'b1');
  });

  test('权重策略按 3:1 平滑分配（A A B A）', () {
    final g = group(strategy: RouteStrategy.weight, members: [m('pA', 'a1', weight: 3), m('pB', 'b1', weight: 1)]);

    final picks = List.generate(4, (_) => service.select(g, providers).config.modelName);

    expect(picks, ['a1', 'a1', 'b1', 'a1']);
  });

  test('智能策略跳过冷却成员并偏向少用的成员', () {
    final g = group(strategy: RouteStrategy.smart, members: [m('pA', 'a1'), m('pB', 'b1')]);

    final first = service.select(g, providers).config;
    service.markMemberSucceeded(first);
    service.markMemberSucceeded(first);
    service.markMemberSucceeded(first);

    // a1 用过 3 次、b1 从未使用：成功率相同下应轮到 b1（均衡微调生效）
    expect(service.select(g, providers).config.modelName, 'b1');
  });

  test('智能策略下失败成员被排除，即使它本该最优先', () {
    final g = group(strategy: RouteStrategy.smart, members: [m('pA', 'a1'), m('pB', 'b1')]);

    service.markMemberFailed(
      const AiConfig(
        providerId: 'pA',
        name: 'a1',
        provider: 'openai',
        modelName: 'a1',
        apiKey: 'k',
        baseUrl: 'https://pA.example.com/v1',
      ),
      Exception('连接超时 timeout'),
    );

    expect(service.select(g, providers).config.modelName, 'b1');
  });

  test('手动策略固定成员；固定项失效时回落首个可用成员', () {
    final g = group(strategy: RouteStrategy.manual, members: [m('pA', 'a1'), m('pB', 'b1')], pinnedMember: 'pB::b1');
    expect(service.select(g, providers).config.modelName, 'b1');

    final stale = group(
      strategy: RouteStrategy.manual,
      members: [m('pA', 'a1'), m('pB', 'b1')],
      pinnedMember: 'pZ::zz',
    );
    expect(service.select(stale, providers).config.modelName, 'a1');
  });

  test('成员模型被停用/厂商被删时自动跳过', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pGone', 'x'), m('pA', 'a9'), m('pB', 'b1')]);

    expect(service.select(g, providers).config.modelName, 'b1');
  });

  test('厂商被手动停用时该厂商的成员让位给其它厂商', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pA', 'a1'), m('pB', 'b1')]);
    // pA 停用：模型仍留在条目里，只是不参与选路
    final withDisabled = [providers.first.copyWith(enabled: false), providers[1]];

    expect(service.select(g, withDisabled).config.modelName, 'b1');

    // 组内成员所属厂商全部停用时等同于「没有可用成员」
    expect(() => service.select(g, [withDisabled.first]), throwsA(isA<NoModelConfiguredException>()));
  });

  test('组内没有任何可用成员时抛「未配置」异常（交给角色回落与引导）', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pGone', 'x')]);

    expect(() => service.select(g, providers), throwsA(isA<NoModelConfiguredException>()));
  });

  test('组内启用开关关掉的成员不参与选路', () {
    final g = group(
      strategy: RouteStrategy.rotate,
      members: [
        const RouteGroupMember(providerId: 'pA', modelName: 'a1', enabled: false),
        m('pB', 'b1'),
      ],
    );

    expect(service.select(g, providers).config.modelName, 'b1');
  });

  test('preferVision 且组内确有识图成员时只在其间选路', () {
    // 模型名的视觉线索启发式（含 -vl / vision 等）：无需探测请求即可判定
    final visionProviders = [
      provider('pV', ['qwen-vl-max']),
      provider('pT', ['plain-chat']),
    ];
    final g = group(strategy: RouteStrategy.rotate, members: [m('pV', 'qwen-vl-max'), m('pT', 'plain-chat')]);

    final selection = service.select(g, visionProviders, preferVision: true);
    expect(selection.config.modelName, 'qwen-vl-max');
    expect(selection.requireVision, isTrue);

    // 多轮选路都应收敛在识图成员上，而不是轮流到看不见图的模型
    for (var i = 0; i < 3; i++) {
      final again = service.select(g, visionProviders, preferVision: true);
      expect(again.config.modelName, 'qwen-vl-max');
      expect(again.requireVision, isTrue);
    }
  });

  test('不带图片请求时不收敛，仍按策略轮换', () {
    final visionProviders = [
      provider('pV', ['qwen-vl-max']),
      provider('pT', ['plain-chat']),
    ];
    final g = group(strategy: RouteStrategy.rotate, members: [m('pV', 'qwen-vl-max'), m('pT', 'plain-chat')]);

    final picks = List.generate(2, (_) => service.select(g, visionProviders).config.modelName);
    expect(picks, ['qwen-vl-max', 'plain-chat']);
  });

  test('组关闭「优先识图」时不做收敛', () {
    final visionProviders = [
      provider('pV', ['qwen-vl-max']),
      provider('pT', ['plain-chat']),
    ];
    final g = group(
      strategy: RouteStrategy.rotate,
      members: [m('pV', 'qwen-vl-max'), m('pT', 'plain-chat')],
      preferVision: false,
    );

    final selection = service.select(g, visionProviders, preferVision: true);
    expect(selection.requireVision, isFalse);
  });

  test('AiModelRoute.next 依次尝试其余成员，用尽后返回 null，且不改动已用成员', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pA', 'a1'), m('pB', 'b1'), m('pC', 'c1')]);
    final selection = service.select(g, providers);
    final route = selection.toRoute();

    final first = route.initial;
    expect(first.modelName, 'a1');

    final second = route.next(first, Exception('429 rate limit'));
    expect(second?.modelName, 'b1');
    final third = route.next(second!, Exception('502 bad gateway'));
    expect(third?.modelName, 'c1');
    // 三个成员都试过：不再无限切换
    expect(route.next(third!, Exception('timeout')), isNull);
  });

  test('requireVision 的 route 不会切换到看不见图的成员', () {
    final visionProviders = [
      provider('pV', ['qwen-vl-max']),
      provider('pT', ['plain-chat']),
    ];
    final g = group(strategy: RouteStrategy.rotate, members: [m('pV', 'qwen-vl-max'), m('pT', 'plain-chat')]);
    final route = service.select(g, visionProviders, preferVision: true).toRoute();

    expect(route.requireVision, isTrue);
    expect(route.next(route.initial, Exception('429')), isNull);
  });

  test('advance: false 的预检不推进轮次（否则真正请求会「跳号」）', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pA', 'a1'), m('pB', 'b1'), m('pC', 'c1')]);

    // 连续预检都停在同一个成员上，且不写「上次使用」
    for (var i = 0; i < 3; i++) {
      final peek = service.select(g, providers, advance: false);
      expect(peek.config.modelName, 'a1');
    }
    expect(service.lastUsedMember(g.id), isNull);

    // 真正的请求仍按顺序从第一个成员开始
    expect(service.select(g, providers).config.modelName, 'a1');
    expect(service.select(g, providers).config.modelName, 'b1');
  });

  test('权重策略下预检同样不消耗权重轮次', () {
    final g = group(strategy: RouteStrategy.weight, members: [m('pA', 'a1', weight: 3), m('pB', 'b1', weight: 1)]);

    for (var i = 0; i < 5; i++) {
      expect(service.select(g, providers, advance: false).config.modelName, 'a1');
    }

    final picks = List.generate(4, (_) => service.select(g, providers).config.modelName);
    expect(picks, ['a1', 'a1', 'b1', 'a1']);
  });

  test('成员失败进入冷却，冷却结束自动回池', () {
    final g = group(strategy: RouteStrategy.failover, members: [m('pA', 'a1'), m('pB', 'b1')]);
    final config = service.select(g, providers).config;

    service.markMemberFailed(config, Exception('429 too many requests'));
    expect(service.isCooling('pA::a1'), isTrue);
    expect(service.select(g, providers).config.modelName, 'b1');

    service.resetMember('pA::a1');
    expect(service.isCooling('pA::a1'), isFalse);
    expect(service.select(g, providers).config.modelName, 'a1');
  });

  test('resetGroup 清掉游标与成员健康度（改了配置不该沿用旧轮次）', () {
    final g = group(strategy: RouteStrategy.rotate, members: [m('pA', 'a1'), m('pB', 'b1')]);
    service.select(g, providers);
    expect(service.lastUsedMember(g.id), 'pA::a1');

    service.resetGroup(g.id, members: g.members);
    expect(service.lastUsedMember(g.id), isNull);
    expect(service.select(g, providers).config.modelName, 'a1');
  });
}
