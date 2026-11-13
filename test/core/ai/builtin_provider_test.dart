import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_provider.dart';
import 'package:qnote_flutter/core/utils/image_model_detection.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/builtin_service_config.dart';

BuiltinServiceConfig _config({
  bool imageEnabled = false,
  bool maintenance = false,
  bool enabled = true,
  int contextWindow = 1048576,
  bool vision = true,
}) {
  return BuiltinServiceConfig(
    version: 1,
    updatedAtRaw: '2026-11-13T03:18:16Z',
    minAppVersion: '0.1.0',
    enabled: enabled,
    chat: BuiltinCapability(
      enabled: true,
      model: BuiltinProvider.chatModelId,
      displayName: '小Q 免费模型',
      baseUrl: 'https://demo.trycloudflare.com/v1',
      contextWindow: contextWindow,
      vision: vision,
    ),
    image: BuiltinCapability(enabled: imageEnabled, model: BuiltinProvider.imageModelId, displayName: '小Q 免费生图'),
    maintenance: maintenance,
    maintenanceMessage: maintenance ? '维护中' : '',
    signature: 'test',
  );
}

void main() {
  group('BuiltinProvider.fromConfig', () {
    test('无配置时返回 null', () {
      expect(BuiltinProvider.fromConfig(null), isNull);
    });

    test('默认只有对话模型，且免密钥、免费、支持识图', () {
      final provider = BuiltinProvider.fromConfig(_config());

      expect(provider, isNotNull);
      expect(provider!.id, BuiltinProvider.id);
      expect(provider.vendorId, BuiltinProvider.vendorId);
      expect(provider.baseUrl, 'https://demo.trycloudflare.com/v1');
      expect(provider.apiKeys, isEmpty);
      expect(provider.hasCredentials, isTrue, reason: '内置服务走 vendorAllowsKeyless');
      expect(provider.isUsable, isTrue);
      expect(provider.models, hasLength(1));

      final model = provider.models.single;
      expect(model.id, BuiltinProvider.chatModelId);
      expect(model.name, '小Q 免费模型');
      expect(model.isFree, isTrue);
      expect(model.contextWindow, 1048576);
      expect(model.supportsVision, isTrue);
      expect(model.supportsImageGeneration, isNull);
    });

    test('生图开关打开后追加生图模型，并能被生图筛选识别', () {
      final provider = BuiltinProvider.fromConfig(_config(imageEnabled: true));

      expect(provider, isNotNull);
      expect(provider!.models, hasLength(2));
      final image = provider.models.firstWhere((m) => m.id == BuiltinProvider.imageModelId);
      expect(image.supportsImageGeneration, isTrue);
      expect(isImageGenerationModel(image), isTrue);
      expect(provider.hasModel(BuiltinProvider.imageModelId), isTrue);
    });

    test('维护中保留条目但置为停用', () {
      final provider = BuiltinProvider.fromConfig(_config(maintenance: true));

      expect(provider, isNotNull);
      expect(provider!.enabled, isFalse);
      expect(provider.isUsable, isFalse);
      expect(provider.models, isNotEmpty);
    });

    test('总开关关闭时同样停用', () {
      final provider = BuiltinProvider.fromConfig(_config(enabled: false));
      expect(provider, isNotNull);
      expect(provider!.enabled, isFalse);
    });

    test('isBuiltinId 只命中固定 id', () {
      expect(BuiltinProvider.isBuiltinId(BuiltinProvider.id), isTrue);
      expect(BuiltinProvider.isBuiltinId('builtin_qnote'), isFalse);
      expect(BuiltinProvider.isBuiltinId(null), isFalse);
    });
  });

  group('mergeBuiltinProvider', () {
    test('无内置时保持用户列表不变', () {
      final users = <AiProvider>[_userProvider('user-1'), _userProvider('user-2')];
      expect(mergeBuiltinProvider(users, null).map((p) => p.id).toList(), <String>['user-1', 'user-2']);
    });

    test('内置虚拟厂商追加在末尾', () {
      final users = <AiProvider>[_userProvider('user-1')];
      final builtin = BuiltinProvider.fromConfig(_config());
      final merged = mergeBuiltinProvider(users, builtin);
      expect(merged.map((p) => p.id).toList(), <String>['user-1', BuiltinProvider.id]);
    });

    test('过滤历史备份里混入的内置行', () {
      final stored = <AiProvider>[_userProvider('user-1'), _userProvider(BuiltinProvider.id), _userProvider('user-2')];
      final builtin = BuiltinProvider.fromConfig(_config());
      final merged = mergeBuiltinProvider(stored, builtin);
      expect(merged.where((p) => p.id == BuiltinProvider.id), hasLength(1));
      expect(merged.map((p) => p.id).toList(), <String>['user-1', 'user-2', BuiltinProvider.id]);
    });
  });
}

AiProvider _userProvider(String id) {
  return AiProvider(
    id: id,
    name: '用户服务 $id',
    providerType: 'openai',
    baseUrl: 'https://example.com/v1',
    apiKeys: const <String>['sk-test'],
    models: const <AiProviderModel>[AiProviderModel(id: 'test-model', name: 'test-model')],
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}
