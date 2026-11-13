import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/models.dart';

/// 图标资源目录（测试的工作目录是项目根）
const String _iconDir = 'assets/images/vendors';

void main() {
  group('AiProviderConfig Tests', () {
    test('Agnes AI provider is configured correctly', () {
      final provider = getProviderById('agnes');
      expect(provider, isNotNull);
      expect(provider!.name, 'Agnes AI');
      expect(provider.provider, 'openai');
      expect(provider.defaultBaseUrl, 'https://apihub.agnes-ai.com/v1');
      expect(provider.models, contains('agnes-2.0-flash'));
      expect(provider.models, contains('agnes-1.5-flash'));
      expect(provider.models, contains('agnes-image-2.1-flash'));
      expect(provider.models, contains('agnes-image-2.0-flash'));
      expect(provider.models, contains('agnes-video-2.0'));
      expect(provider.modelsEndpoint, '/v1/models');
      expect(provider.urlRequired, isTrue);
    });

    test('All providers have unique IDs', () {
      final ids = aiProviders.map((p) => p.id).toList();
      final uniqueIds = ids.toSet();
      expect(ids.length, uniqueIds.length);
    });
    test('厂商选择器按凭证类型分区：账号登录型与 API Key 型不重叠且覆盖全部', () {
      final account = aiAccountProviders();
      final apiKey = aiApiKeyProviders();

      // 账号登录型目前是小浣熊；这两组必须互斥、且合起来等于全部模板，
      // 否则「添加模型服务」的分区列表会漏厂商
      expect(account.map((p) => p.id), contains('raccoon'));
      expect(account.every((p) => p.authMode != 'api_key'), isTrue);
      expect(apiKey.every((p) => p.authMode == 'api_key'), isTrue);
      expect(apiKey.map((p) => p.id), isNot(contains('raccoon')));
      expect({...account.map((p) => p.id), ...apiKey.map((p) => p.id)}, aiProviders.map((p) => p.id).toSet());
    });

    test('老用户的 vendorId 仍然命中模板（改名会让图标与默认地址一起失效）', () {
      // 这些 id 是历史版本写入数据库的取值，重命名等于让老条目的模板匹配断掉
      for (final legacyId in const ['deepseek', 'openai', 'moonshot', 'mimo', 'longcat', 'zhipu', 'custom']) {
        expect(getProviderById(legacyId), isNotNull, reason: '厂商 id $legacyId 不能改名或删除');
      }
    });

    test('协议取值只允许 openai / anthropic / gemini', () {
      for (final spec in aiProviders) {
        expect(
          const ['openai', 'anthropic', 'gemini'],
          contains(spec.provider),
          reason: '${spec.id} 声明了未实现的协议 ${spec.provider}',
        );
      }
    });

    test('Anthropic 厂商走 Messages 协议与 x-api-key 鉴权', () {
      final anthropic = getProviderById('anthropic');
      expect(anthropic, isNotNull);
      expect(anthropic!.provider, 'anthropic');
      expect(anthropic.authType, 'x_api_key');
      expect(anthropic.defaultBaseUrl, 'https://api.anthropic.com');
    });
  });

  group('厂商分组', () {
    test('每个分组都有厂商，不存在空分组（空分组会在选择器里留下空 chips）', () {
      final used = aiProviders.map((p) => p.category).toSet();
      for (final category in VendorCategory.values) {
        expect(used, contains(category), reason: '分组 ${category.label} 没有任何厂商');
      }
    });

    test('免密钥厂商只能出现在聚合中转里', () {
      for (final spec in aiProviders.where((s) => s.keyOptional)) {
        expect(spec.category, VendorCategory.relay, reason: '${spec.id} 声明了可空密钥，但它不是免密钥网关');
      }
    });
  });

  group('图标资源', () {
    test('声明了图标的厂商都能解析到资源（漏拷资源会让界面出现空方块）', () {
      for (final spec in aiProviders.where((s) => s.icon.isNotEmpty)) {
        final file = File('$_iconDir/${spec.icon}.svg');
        expect(file.existsSync(), isTrue, reason: '${spec.id} 的图标 ${spec.icon}.svg 缺失');
      }
    });
  });

  group('多端点声明', () {
    test('端点 id 唯一、地址形如 URL', () {
      for (final spec in aiProviders.where((s) => s.regions.isNotEmpty)) {
        final ids = spec.regions.map((r) => r.id).toList();
        expect(ids.length, ids.toSet().length, reason: '${spec.id} 的端点 id 重复');
        for (final region in spec.regions) {
          expect(
            region.baseUrl.startsWith('http://') || region.baseUrl.startsWith('https://'),
            isTrue,
            reason: '${spec.id}/${region.id} 的地址不是合法 URL：${region.baseUrl}',
          );
        }
      }
    });

    test('带端点的厂商必须有默认地址（否则新建后选择器没有选中项）', () {
      for (final spec in aiProviders.where((s) => s.regions.isNotEmpty)) {
        expect(spec.defaultBaseUrl, isNotEmpty, reason: '${spec.id} 声明了端点却没有默认地址');
      }
    });
  });
}
