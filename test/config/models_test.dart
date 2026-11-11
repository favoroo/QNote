import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/models.dart';

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
  });
}
