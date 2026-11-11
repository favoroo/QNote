import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/widgets/ai/assistant_model_sheet.dart';

AiProvider _provider({
  required String id,
  required String name,
  required List<String> models,
  bool enabled = true,
}) => AiProvider(
  id: id,
  vendorId: 'custom',
  name: name,
  providerType: 'openai',
  baseUrl: 'https://example.com/v1',
  apiKeys: const ['sk-test'],
  models: models.map((m) => AiProviderModel.of(m)).toList(),
  isDefault: false,
  enabled: enabled,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

AiRouteGroup _group({
  required String id,
  required String name,
  List<RouteGroupMember> members = const [],
}) => AiRouteGroup(
  id: id,
  name: name,
  members: members,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  final main = _provider(id: 'p1', name: '主力', models: ['gpt-5.4']);
  final backup = _provider(id: 'p2', name: '备用', models: ['glm-4.6']);
  final disabled = _provider(
    id: 'p3',
    name: '停用厂商',
    models: ['gpt-5.4'],
    enabled: false,
  );

  group('最近使用条目', () {
    test('保留调用方给的顺序，模型行带厂商名', () {
      final entries = recentBindingEntries(
        const [
          AiModelRef(providerId: 'p2', modelName: 'glm-4.6'),
          AiModelRef(providerId: 'p1', modelName: 'gpt-5.4'),
        ],
        [main, backup],
        const [],
      );
      expect(entries.map((e) => e.name), ['glm-4.6', 'gpt-5.4']);
      expect(entries.first.providerName, '备用');
      expect(entries.first.isGroup, isFalse);
    });

    test('已删除的厂商、已停用厂商、失效模型全部跳过', () {
      final entries = recentBindingEntries(
        const [
          AiModelRef(providerId: 'p9', modelName: '已删除'),
          AiModelRef(providerId: 'p3', modelName: 'gpt-5.4'),
          AiModelRef(providerId: 'p1', modelName: '已下架'),
          AiModelRef(providerId: 'p1', modelName: 'gpt-5.4'),
        ],
        [main, disabled],
        const [],
      );
      expect(entries.map((e) => e.ref.modelName), ['gpt-5.4']);
    });

    test('路由组给组名与成员摘要，没有可用成员的组跳过', () {
      final live = _group(
        id: 'g1',
        name: '故障转移组',
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'gpt-5.4'),
        ],
      );
      final empty = _group(id: 'g2', name: '空组');
      final entries = recentBindingEntries(
        const [
          AiModelRef(providerId: 'g1', modelName: AiModelRef.groupMarker),
          AiModelRef(providerId: 'g2', modelName: AiModelRef.groupMarker),
          AiModelRef(providerId: 'g9', modelName: AiModelRef.groupMarker),
        ],
        [main, backup],
        [live, empty],
      );
      expect(entries, hasLength(1));
      expect(entries.single.name, '故障转移组');
      expect(entries.single.isGroup, isTrue);
      expect(entries.single.providerName, isNull);
      expect(entries.single.meta, contains('个模型'));
    });

    test('空输入返回空列表', () {
      expect(recentBindingEntries(const [], [main], const []), isEmpty);
    });
  });
}
