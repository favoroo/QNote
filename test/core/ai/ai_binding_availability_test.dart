import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';

/// 绑定可用性判据的单元测试
///
/// 两个入口的分工是「停用厂商」这个可逆动作的核心：
/// - [isBindingUsable]：现在能不能用到（界面回落、实际发信都按它走）；
/// - [isBindingResolvable]：绑定值不值得留着（清理陈旧绑定按它走，停用不算失效）。
void main() {
  final now = DateTime(2026, 1, 1);

  AiProvider provider(String id, {List<String> models = const ['m1'], bool enabled = true}) => AiProvider(
    id: id,
    name: id,
    providerType: 'openai',
    baseUrl: 'https://$id.example.com/v1',
    apiKeys: const ['sk-test'],
    models: models.map((m) => AiProviderModel.of(m)).toList(),
    enabled: enabled,
    createdAt: now,
    updatedAt: now,
  );

  AiRouteGroup group(String id, List<RouteGroupMember> members) =>
      AiRouteGroup(id: id, name: id, strategy: RouteStrategy.rotate, members: members, createdAt: now, updatedAt: now);

  RouteGroupMember member(String providerId, String modelName) =>
      RouteGroupMember(providerId: providerId, modelName: modelName);

  test('停用厂商：当前用不到，但绑定不算失效（可恢复）', () {
    const ref = AiModelRef(providerId: 'p1', modelName: 'm1');
    final disabled = [provider('p1', enabled: false)];

    expect(isBindingUsable(ref, disabled, const []), isFalse);
    expect(isBindingResolvable(ref, disabled, const []), isTrue);
    // 重新启用后原绑定照旧生效，不需要用户重配
    expect(isBindingUsable(ref, [provider('p1')], const []), isTrue);
  });

  test('模型被逐条停用（移出 models）才算真失效', () {
    const ref = AiModelRef(providerId: 'p1', modelName: 'm1');
    final withoutModel = [
      provider('p1', models: const ['m2']),
    ];

    expect(isBindingUsable(ref, withoutModel, const []), isFalse);
    expect(isBindingResolvable(ref, withoutModel, const []), isFalse);
  });

  test('未绑定（null）在两种判据下都算不可用', () {
    expect(isBindingUsable(null, const [], const []), isFalse);
    expect(isBindingResolvable(null, const [], const []), isFalse);
  });

  test('路由组：成员厂商被停用时组当前不可用，但组绑定保留', () {
    final ref = AiModelRef.routeGroup('g1');
    final groups = [
      group('g1', [member('p1', 'm1')]),
    ];
    final disabled = [provider('p1', enabled: false)];

    expect(isBindingUsable(ref, disabled, groups), isFalse);
    expect(isBindingResolvable(ref, disabled, groups), isTrue);

    // 组里只要还有一个未停用的成员，整组就仍然可用
    final mixed = [provider('p1', enabled: false), provider('p2')];
    final mixedGroups = [
      group('g1', [member('p1', 'm1'), member('p2', 'm1')]),
    ];
    expect(isBindingUsable(ref, mixed, mixedGroups), isTrue);
  });

  test('路由组：组被删或成员模型全被停用时绑定失效', () {
    final ref = AiModelRef.routeGroup('g1');

    expect(isBindingResolvable(ref, [provider('p1')], const []), isFalse);

    final groups = [
      group('g1', [member('p1', 'm-gone')]),
    ];
    expect(isBindingResolvable(ref, [provider('p1')], groups), isFalse);
  });
}
