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
  });
}
