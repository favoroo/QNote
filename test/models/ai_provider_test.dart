import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

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

    test('厂商级停用：默认启用、落库往返、缺列按启用处理', () {
      AiProvider build({bool enabled = true}) => AiProvider(
            id: 'p',
            name: 'p',
            providerType: 'openai',
            baseUrl: 'https://x/v1',
            apiKeys: const ['sk'],
            models: const [AiProviderModel(id: 'm', name: 'm')],
            enabled: enabled,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          );

      expect(build().enabled, isTrue);
      expect(build().toMap()['enabled'], 1);
      expect(build(enabled: false).toMap()['enabled'], 0);
      expect(AiProvider.fromMap(build(enabled: false).toMap()).enabled, isFalse);
      // 老库/旧备份没有这一列，升级后不能集体失效
      final legacy = build().toMap()..remove('enabled');
      expect(AiProvider.fromMap(legacy).enabled, isTrue);
    });

    test('停用的厂商一律不可用，即便密钥与模型都齐全', () {
      final provider = AiProvider(
        id: 'p',
        name: 'p',
        providerType: 'openai',
        baseUrl: 'https://x/v1',
        apiKeys: const ['sk'],
        models: const [AiProviderModel(id: 'm', name: 'm')],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      expect(provider.isUsable, isTrue);
      final disabled = provider.copyWith(enabled: false);
      expect(disabled.isUsable, isFalse);
      // 停用不动密钥与已启用模型，重新启用即恢复
      expect(disabled.apiKeys, ['sk']);
      expect(disabled.models.single.id, 'm');
      expect(disabled.copyWith(enabled: true).isUsable, isTrue);
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

  group('AiProviderModel 计费元数据', () {
    test('toMap / fromMap 往返保留倍率、上下文、限免说明与能力', () {
      final model = AiProviderModel.of(
        'sn-sensenova-6-8-flash',
        name: 'SenseNova-6.8-Flash',
        rate: 0,
        rateWas: 0.5,
        contextWindow: 256000,
        rateNote: '限免至11月30日',
        supportsVision: true,
        supportsImageGeneration: false,
      );

      final restored = AiProviderModel.fromMap(model.toMap());

      expect(restored.rate, 0);
      expect(restored.rateWas, 0.5);
      expect(restored.contextWindow, 256000);
      expect(restored.rateNote, '限免至11月30日');
      expect(restored.supportsVision, isTrue);
      // 厂商明确声明了输出模态（text）时，false 也要落库，不能丢成未知
      expect(restored.supportsImageGeneration, isFalse);
      expect(restored.isFree, isTrue);
      expect(restored.hasDiscount, isTrue);
    });

    test('旧 JSON 没有元数据字段时按未知处理，不是 0 / false', () {
      final restored = AiProviderModel.fromMap({
        'id': 'm',
        'name': 'm',
        'reasoning_effort': 'high',
      });

      expect(restored.rate, isNull);
      expect(restored.rateWas, isNull);
      expect(restored.contextWindow, isNull);
      expect(restored.rateNote, isNull);
      expect(restored.supportsVision, isNull);
      expect(restored.supportsImageGeneration, isNull);
      // 没给倍率就不算免费，否则会凭空多出一个「免费」标
      expect(restored.isFree, isFalse);
      expect(restored.hasDiscount, isFalse);
      expect(restored.toMap().containsKey('rate'), isFalse);
      expect(restored.toMap().containsKey('vision'), isFalse);
      expect(restored.toMap().containsKey('image_gen'), isFalse);
    });

    test('withMetadataFrom 只覆盖元数据，名称与思考档位保持本地设置', () {
      final local = AiProviderModel.of(
        'sn-glm-5-3',
        name: '我改过的名字',
        reasoningEffort: ReasoningEffort.high,
        rate: 1,
        contextWindow: 1000000,
      );
      final fresh = AiProviderModel.of(
        'sn-glm-5-3',
        name: '厂商新名字',
        rate: 0.75,
        rateWas: 1,
        contextWindow: 1000000,
        rateNote: '限时 7.5 折',
        supportsVision: true,
        supportsImageGeneration: true,
      );

      final merged = local.withMetadataFrom(fresh);

      expect(merged.name, '我改过的名字');
      expect(merged.reasoningEffort, ReasoningEffort.high);
      expect(merged.rate, 0.75);
      expect(merged.rateWas, 1);
      expect(merged.rateNote, '限时 7.5 折');
      expect(merged.supportsVision, isTrue);
      expect(merged.supportsImageGeneration, isTrue);
    });

    test('copyWith 保留元数据，只改思考档位', () {
      final model = AiProviderModel.of(
        'm',
        rate: 0.25,
        contextWindow: 1000000,
      );

      final updated = model.copyWith(reasoningEffort: ReasoningEffort.low);

      expect(updated.reasoningEffort, ReasoningEffort.low);
      expect(updated.rate, 0.25);
      expect(updated.contextWindow, 1000000);
    });
  });

  group('AiProviderModel 自定义思考档位', () {
    test('toMap / fromMap 往返，并按由弱到强排序', () {
      final model = AiProviderModel.of(
        'gpt-5.4-mini',
        reasoningEfforts: [
          ReasoningEffort.max,
          ReasoningEffort.minimal,
          ReasoningEffort.low,
        ],
      );

      final restored = AiProviderModel.fromMap(model.toMap());

      expect(restored.reasoningEfforts, [
        ReasoningEffort.minimal,
        ReasoningEffort.low,
        ReasoningEffort.max,
      ]);
      expect(restored.toMap()['reasoning_efforts'], [
        'minimal',
        'low',
        'max',
      ]);
    });

    test('未设置自定义档位时不写字段，旧数据按自动识别处理', () {
      final model = AiProviderModel.fromMap({'id': 'm', 'name': 'm'});

      expect(model.reasoningEfforts, isNull);
      expect(model.toMap().containsKey('reasoning_efforts'), isFalse);
    });

    test('空集合按自动识别处理', () {
      final model = AiProviderModel.of('m', reasoningEfforts: const []);

      expect(model.reasoningEfforts, isNull);
    });

    test('copyWith 可清空自定义档位，也可只改当前档位', () {
      final model = AiProviderModel.of(
        'm',
        reasoningEffort: ReasoningEffort.high,
        reasoningEfforts: [ReasoningEffort.low, ReasoningEffort.high],
      );

      expect(model.copyWith(reasoningEfforts: null).reasoningEfforts, isNull);
      // 未传自定义档位时保留原集合
      final updated = model.copyWith(reasoningEffort: ReasoningEffort.low);
      expect(updated.reasoningEffort, ReasoningEffort.low);
      expect(updated.reasoningEfforts, [
        ReasoningEffort.low,
        ReasoningEffort.high,
      ]);
    });

    test('withMetadataFrom 保留自定义档位', () {
      final local = AiProviderModel.of(
        'm',
        reasoningEfforts: [ReasoningEffort.xhigh],
      );

      final merged = local.withMetadataFrom(
        AiProviderModel.of('m', rate: 0.5),
      );

      expect(merged.reasoningEfforts, [ReasoningEffort.xhigh]);
      expect(merged.rate, 0.5);
    });

    test('相等性包含档位集合内容，顺序归一后视为相等', () {
      final a = AiProviderModel.of(
        'm',
        reasoningEfforts: [ReasoningEffort.low, ReasoningEffort.high],
      );
      final b = AiProviderModel.of(
        'm',
        reasoningEfforts: [ReasoningEffort.high, ReasoningEffort.low],
      );

      expect(a, b);
      expect(
        a ==
            AiProviderModel.of(
              'm',
              reasoningEfforts: [ReasoningEffort.high],
            ),
        isFalse,
      );
    });
  });
}