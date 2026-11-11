import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';

void main() {
  group('AiModelRef 路由组引用', () {
    test('组引用编码为 组id::__route_group__ 并可往返解析', () {
      final ref = AiModelRef.routeGroup('group-1');
      expect(ref.isRouteGroup, isTrue);
      expect(ref.encode(), 'group-1::__route_group__');
      expect(AiModelRef.tryParse(ref.encode()), ref);
    });

    test('具体模型引用不会被误判为路由组', () {
      const ref = AiModelRef(providerId: 'p1', modelName: 'm1');
      expect(ref.isRouteGroup, isFalse);
      expect(AiModelRef.tryParse(ref.encode())!.isRouteGroup, isFalse);
    });
  });

  group('RouteGroupMember', () {
    test('JSON 往返保留权重与启用状态', () {
      const members = [
        RouteGroupMember(providerId: 'p1', modelName: 'm1', weight: 3),
        RouteGroupMember(providerId: 'p2', modelName: 'm2', weight: 1, enabled: false),
      ];
      final decoded = RouteGroupMember.listFromJson(RouteGroupMember.listToJson(members));
      expect(decoded, members);
    });

    test('权重被夹在 1~9，重复成员只保留一份', () {
      final decoded = RouteGroupMember.listFromJson(
        '[{"providerId":"p1","modelName":"m1","weight":99},'
        '{"providerId":"p1","modelName":"m1","weight":1},'
        '{"providerId":"p2","modelName":"m2","weight":0}]',
      );
      expect(decoded.length, 2);
      expect(decoded.first.weight, RouteGroupMember.maxWeight);
      expect(decoded.last.weight, RouteGroupMember.minWeight);
    });

    test('编码沿用 AiModelRef 格式，行内修改权重用 copyWith', () {
      const member = RouteGroupMember(providerId: 'p1', modelName: 'm1');
      expect(member.encode(), 'p1::m1');
      expect(member.copyWith(weight: 5).weight, 5);
      expect(member.copyWith(enabled: false).enabled, isFalse);
    });
  });

  group('AiRouteGroup', () {
    test('toMap/fromMap 往返保留策略、成员、固定成员与识图偏好', () {
      final now = DateTime(2026, 1, 2, 3, 4, 5);
      final group = AiRouteGroup(
        id: 'g1',
        name: '主模型池',
        strategy: RouteStrategy.weight,
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'm1', weight: 3),
          RouteGroupMember(providerId: 'p2', modelName: 'm2', enabled: false),
        ],
        pinnedMember: 'p2::m2',
        preferVision: false,
        createdAt: now,
        updatedAt: now,
      );

      final restored = AiRouteGroup.fromMap(group.toMap());

      expect(restored.id, 'g1');
      expect(restored.name, '主模型池');
      expect(restored.strategy, RouteStrategy.weight);
      expect(restored.members, group.members);
      expect(restored.pinnedMember, 'p2::m2');
      expect(restored.preferVision, isFalse);
      expect(restored.createdAt, now);
    });

    test('未知策略回落为轮流（旧数据/手改配置都能安全打开）', () {
      final restored = AiRouteGroup.fromMap({
        'id': 'g1',
        'name': 'x',
        'strategy': 'something-new',
        'members': '[]',
        'created_at': '2026-01-01T00:00:00.000',
        'updated_at': '2026-01-01T00:00:00.000',
      });
      expect(restored.strategy, RouteStrategy.rotate);
    });

    test('enabledMembers 只含组内启用的成员，hasMember 命中原始列表', () {
      final group = AiRouteGroup(
        id: 'g1',
        name: 'x',
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'm1'),
          RouteGroupMember(providerId: 'p2', modelName: 'm2', enabled: false),
        ],
        createdAt: _epoch,
        updatedAt: _epoch,
      );
      expect(group.enabledMembers.length, 1);
      expect(group.hasMember('p2', 'm2'), isTrue);
      expect(group.hasMember('p3', 'm3'), isFalse);
    });

    test('copyWith 传 null 可清空固定成员（与「不传」区分）', () {
      final group = AiRouteGroup(id: 'g1', name: 'x', pinnedMember: 'p1::m1', createdAt: _epoch, updatedAt: _epoch);
      expect(group.copyWith().pinnedMember, 'p1::m1');
      expect(group.copyWith(pinnedMember: null).pinnedMember, isNull);
    });
  });

  group('RouteStrategy', () {
    test('id 与枚举解耦，fromId 未知值回落轮流', () {
      expect(RouteStrategy.fromId('weight'), RouteStrategy.weight);
      expect(RouteStrategy.fromId(null), RouteStrategy.rotate);
      expect(RouteStrategy.failover.id, 'failover');
    });

    test('除手动外都需要多成员才有意义', () {
      expect(RouteStrategy.rotate.needsMultipleMembers, isTrue);
      expect(RouteStrategy.smart.needsMultipleMembers, isTrue);
      expect(RouteStrategy.manual.needsMultipleMembers, isFalse);
    });
  });
}

final DateTime _epoch = DateTime(2026, 1, 1);
