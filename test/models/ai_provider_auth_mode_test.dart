import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

/// 厂商条目凭证类型的序列化与可用性判据
void main() {
  final now = DateTime(2026, 1, 1);

  AiProvider provider({
    String authMode = AiProvider.authModeApiKey,
    List<String> keys = const ['sk-test'],
    List<AiProviderModel> models = const [
      AiProviderModel(id: 'm1', name: 'm1'),
    ],
  }) {
    return AiProvider(
      id: 'p1',
      vendorId: 'raccoon',
      name: '小浣熊',
      providerType: 'openai',
      baseUrl: 'https://xiaohuanxiong.com/api/web/llm/v2',
      authMode: authMode,
      apiKeys: keys,
      models: models,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('账号型 auth_mode 写入/读出 toMap，且不要求 api_keys', () {
    final saved = provider(
      authMode: AiProvider.authModeRaccoon,
      keys: const [],
    );
    final map = saved.toMap();
    expect(map['auth_mode'], AiProvider.authModeRaccoon);

    final restored = AiProvider.fromMap(map);
    expect(restored.authMode, AiProvider.authModeRaccoon);
    expect(restored.usesAccountAuth, isTrue);
    expect(restored.hasCredentials, isTrue);
    expect(restored.isUsable, isTrue);
  });

  test('旧数据没有 auth_mode 时回落到 api_key', () {
    final map = provider().toMap()..remove('auth_mode');
    final restored = AiProvider.fromMap(map);
    expect(restored.authMode, AiProvider.authModeApiKey);
    expect(restored.usesAccountAuth, isFalse);
  });

  test('api_key 厂商没有密钥时不可用；账号型没有密钥仍可用', () {
    expect(provider(keys: const []).isUsable, isFalse);
    expect(
      provider(authMode: AiProvider.authModeRaccoon, keys: const []).isUsable,
      isTrue,
    );
  });

  test('多账号选号策略与亲和写入/读出，缺失时回落默认值', () {
    final saved = provider(
      authMode: AiProvider.authModeRaccoon,
      keys: const [],
    ).copyWith(accountRouting: 'failover', accountAffinity: 'strict');
    final map = saved.toMap();
    expect(map['account_routing'], 'failover');
    expect(map['account_affinity'], 'strict');

    final restored = AiProvider.fromMap(map);
    expect(restored.accountRouting, 'failover');
    expect(restored.accountAffinity, 'strict');

    final legacy = provider().toMap()
      ..remove('account_routing')
      ..remove('account_affinity');
    final fallback = AiProvider.fromMap(legacy);
    expect(fallback.accountRouting, AiProvider.defaultAccountRouting);
    expect(fallback.accountAffinity, AiProvider.defaultAccountAffinity);
  });

  test('AiConfig.fromProvider 带上 authMode', () {
    final config = AiConfig.fromProvider(
      provider(authMode: AiProvider.authModeRaccoon, keys: const []),
      'm1',
    );
    expect(config.authMode, AiProvider.authModeRaccoon);
    expect(config.usesAccountAuth, isTrue);
    expect(config.apiKey, isEmpty);
  });
}
