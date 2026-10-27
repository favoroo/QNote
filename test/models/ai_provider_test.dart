import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

void main() {
  group('AiModelRef', () {
    test('encode / tryParse 往返', () {
      const ref = AiModelRef(providerId: 'p1', modelName: 'gpt-4o');
      expect(ref.encode(), 'p1::gpt-4o');
      expect(AiModelRef.tryParse(ref.encode()), ref);
    });

    test('模型名里的分隔符保留在模型名一侧', () {
      expect(
        AiModelRef.tryParse('p1::vendor::model'),
        const AiModelRef(providerId: 'p1', modelName: 'vendor::model'),
      );
    });

    test('旧版裸配置 id（无分隔符）解析为 null，按未绑定处理', () {
      expect(AiModelRef.tryParse('6f0c2c8e-uuid-like-id'), isNull);
      expect(AiModelRef.tryParse(''), isNull);
      expect(AiModelRef.tryParse(null), isNull);
      expect(AiModelRef.tryParse('::model'), isNull);
      expect(AiModelRef.tryParse('p1::'), isNull);
    });
  });

  group('AiProvider JSON', () {
    test('toMap / fromMap 往返保留密钥池、启用模型与扫描目录', () {
      final provider = AiProvider(
        id: 'p1',
        vendorId: 'deepseek',
        name: 'DeepSeek 主账号',
        providerType: 'openai',
        baseUrl: 'https://api.deepseek.com',
        apiKeys: const ['sk-a', 'sk-b'],
        models: const [
          AiProviderModel(id: 'deepseek-v4-flash', name: 'Flash'),
          AiProviderModel(id: 'deepseek-v4-pro', name: 'deepseek-v4-pro'),
        ],
        modelCatalog: const [
          AiProviderModel(id: 'deepseek-v4-flash', name: 'Flash'),
          AiProviderModel(id: 'deepseek-v4-pro', name: 'deepseek-v4-pro'),
          AiProviderModel(id: 'deepseek-reasoner', name: 'deepseek-reasoner'),
        ],
        catalogUpdatedAt: DateTime(2026, 10, 27),
        isDefault: true,
        createdAt: DateTime(2026, 10, 1),
        updatedAt: DateTime(2026, 10, 2),
      );

      final restored = AiProvider.fromMap(provider.toMap());

      expect(restored.apiKeys, ['sk-a', 'sk-b']);
      expect(restored.models.map((m) => m.id), ['deepseek-v4-flash', 'deepseek-v4-pro']);
      expect(restored.models.first.name, 'Flash');
      expect(restored.modelCatalog.length, 3);
      expect(restored.isDefault, isTrue);
      expect(restored.catalogUpdatedAt, DateTime(2026, 10, 27));
    });

    test('isUsable 需要地址、密钥与非空模型列表同时到位', () {
      AiProvider build({
        String baseUrl = 'https://x/v1',
        List<String> keys = const ['sk'],
        List<AiProviderModel> models = const [
          AiProviderModel(id: 'm', name: 'm'),
        ],
      }) =>
          AiProvider(
            id: 'p',
            name: 'p',
            providerType: 'openai',
            baseUrl: baseUrl,
            apiKeys: keys,
            models: models,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          );

      expect(build().isUsable, isTrue);
      expect(build(baseUrl: '').isUsable, isFalse);
      expect(build(keys: const []).isUsable, isFalse);
      expect(build(models: const []).isUsable, isFalse);
    });
  });

  group('旧模型级配置归并（ai_configs → 厂商条目）', () {
    final legacyRows = <Map<String, dynamic>>[
      {
        'id': 'cfg-1',
        'name': 'gpt-4o',
        'provider': 'openai',
        'model_name': 'gpt-4o',
        'api_key': 'sk-a',
        'base_url': 'https://api.example.com/v1',
        'is_default': 1,
        'vendor_id': 'openai',
        'created_at': '2026-09-01T10:00:00.000',
        'updated_at': '2026-09-02T10:00:00.000',
      },
      {
        'id': 'cfg-2',
        'name': 'gpt-4o-mini',
        'provider': 'openai',
        'model_name': 'gpt-4o-mini',
        'api_key': 'sk-a',
        'base_url': 'https://api.example.com/v1',
        'is_default': 0,
        'vendor_id': 'openai',
        'created_at': '2026-09-01T11:00:00.000',
        'updated_at': '2026-09-03T10:00:00.000',
      },
      {
        'id': 'cfg-3',
        'name': 'gpt-4o',
        'provider': 'openai',
        'model_name': 'gpt-4o',
        'api_key': 'sk-b',
        'base_url': 'https://api.example.com/v1',
        'is_default': 0,
        'vendor_id': 'openai',
        'created_at': '2026-09-01T12:00:00.000',
        'updated_at': '2026-09-04T10:00:00.000',
      },
      {
        'id': 'cfg-4',
        'name': '另一个地址',
        'provider': 'openai',
        'model_name': 'some-model',
        'api_key': 'sk-c',
        'base_url': 'https://other.example.com/v1',
        'is_default': 0,
        'vendor_id': 'custom',
        'created_at': '2026-09-01T13:00:00.000',
        'updated_at': '2026-09-05T10:00:00.000',
      },
    ];

    test('同 URL 的配置归并为一条厂商，密钥去重合并、模型去重、默认标记保留', () {
      final providers = AiProvider.fromLegacyConfigMaps(legacyRows);

      expect(providers.length, 2);
      final first = providers.first;
      expect(first.baseUrl, 'https://api.example.com/v1');
      expect(first.vendorId, 'openai');
      expect(first.apiKeys, ['sk-a', 'sk-b']);
      expect(first.models.map((m) => m.id), ['gpt-4o', 'gpt-4o-mini']);
      expect(first.isDefault, isTrue);
      expect(first.createdAt, DateTime.parse('2026-09-01T10:00:00.000'));
      expect(first.updatedAt, DateTime.parse('2026-09-04T10:00:00.000'));

      final second = providers.last;
      expect(second.vendorId, 'custom');
      expect(second.apiKeys, ['sk-c']);
      expect(second.models.map((m) => m.id), ['some-model']);
      expect(second.isDefault, isFalse);
    });

    test('缺 vendor_id 的行按 custom 归并', () {
      final providers = AiProvider.fromLegacyConfigMaps([
        {
          'id': 'cfg-x',
          'name': 'x',
          'provider': 'openai',
          'model_name': 'x-model',
          'api_key': 'sk-x',
          'base_url': 'https://x/v1',
          'created_at': '2026-09-01T10:00:00.000',
          'updated_at': '2026-09-01T10:00:00.000',
        },
      ]);
      expect(providers.single.vendorId, 'custom');
    });

    test('空输入不产生厂商', () {
      expect(AiProvider.fromLegacyConfigMaps(const []), isEmpty);
    });
  });
}