import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_service_secret.dart';
import 'package:qnote_flutter/models/builtin_service_config.dart';

/// 按 publish.js 的字段顺序构造配置并签名
Map<String, dynamic> _buildConfig({
  int version = 1,
  String baseUrl = 'https://demo.trycloudflare.com/v1',
  bool imageEnabled = false,
  bool maintenance = false,
  String minAppVersion = '0.1.94',
  String updatedAt = '2026-11-13T03:18:16Z',
}) {
  final config = <String, dynamic>{
    'version': version,
    'updatedAt': updatedAt,
    'minAppVersion': minAppVersion,
    'enabled': !maintenance,
    'chat': <String, dynamic>{
      'enabled': true,
      'baseUrl': baseUrl,
      'model': 'qnote-free',
      'displayName': '小Q 免费模型',
      'contextWindow': 1048576,
      'vision': true,
    },
    'image': <String, dynamic>{'enabled': imageEnabled, 'model': 'qnote-image-free', 'displayName': '小Q 免费生图'},
    'maintenance': <String, dynamic>{'enabled': maintenance, 'message': maintenance ? '维护中' : ''},
  };
  final canonical = <String>[
    '${config['version']}',
    config['updatedAt'] as String,
    config['minAppVersion'] as String,
    '${config['enabled']}',
    '${(config['chat'] as Map)['enabled']}',
    (config['chat'] as Map)['baseUrl'] as String,
    (config['chat'] as Map)['model'] as String,
    (config['chat'] as Map)['displayName'] as String,
    '${(config['chat'] as Map)['contextWindow']}',
    '${(config['chat'] as Map)['vision']}',
    '${(config['image'] as Map)['enabled']}',
    (config['image'] as Map)['model'] as String,
    (config['image'] as Map)['displayName'] as String,
    '${(config['maintenance'] as Map)['enabled']}',
    (config['maintenance'] as Map)['message'] as String,
  ].join('\n');
  config['sig'] = Hmac(sha256, utf8.encode(builtinConfigChecksumKey)).convert(utf8.encode(canonical)).toString();
  return config;
}

void main() {
  group('BuiltinServiceConfig.tryParse', () {
    test('合法配置解析出对话与生图能力', () {
      final config = BuiltinServiceConfig.tryParse(jsonEncode(_buildConfig(imageEnabled: true)));

      expect(config, isNotNull);
      expect(config!.version, 1);
      expect(config.chat.model, 'qnote-free');
      expect(config.baseUrl, 'https://demo.trycloudflare.com/v1');
      expect(config.hasChat, isTrue);
      expect(config.hasImage, isTrue);
      expect(config.isUsable, isTrue);
      expect(config.verifySignature(), isTrue);
    });

    test('生图默认关闭时 hasImage 为 false', () {
      final config = BuiltinServiceConfig.tryParse(jsonEncode(_buildConfig()));
      expect(config, isNotNull);
      expect(config!.hasImage, isFalse);
    });

    test('签名被篡改时拒绝', () {
      final json = _buildConfig();
      json['sig'] = List<String>.filled(64, '0').join();
      expect(BuiltinServiceConfig.tryParse(jsonEncode(json)), isNull);
    });

    test('baseUrl 不是 https 时拒绝', () {
      final json = _buildConfig(baseUrl: 'http://demo.trycloudflare.com/v1');
      expect(BuiltinServiceConfig.tryParse(jsonEncode(json)), isNull);
    });

    test('baseUrl 指向未知域名时拒绝', () {
      final json = _buildConfig(baseUrl: 'https://evil.example.com/v1');
      expect(BuiltinServiceConfig.tryParse(jsonEncode(json)), isNull);
    });

    test('维护模式保留配置但标记不可用', () {
      final config = BuiltinServiceConfig.tryParse(jsonEncode(_buildConfig(maintenance: true)));
      expect(config, isNotNull);
      expect(config!.maintenance, isTrue);
      expect(config.isUsable, isFalse);
      expect(config.maintenanceMessage, '维护中');
    });

    test('版本号缺失或非正数时拒绝', () {
      final json = _buildConfig();
      json['version'] = 0;
      expect(BuiltinServiceConfig.tryParse(jsonEncode(json)), isNull);
    });
  });

  group('BuiltinServiceConfig.isAllowedBaseUrl', () {
    test('只允许受信任的 https 域名', () {
      expect(BuiltinServiceConfig.isAllowedBaseUrl('https://a.trycloudflare.com/v1'), isTrue);
      expect(BuiltinServiceConfig.isAllowedBaseUrl('http://a.trycloudflare.com/v1'), isFalse);
      expect(BuiltinServiceConfig.isAllowedBaseUrl('https://localhost/v1'), isFalse);
      expect(BuiltinServiceConfig.isAllowedBaseUrl('https://127.0.0.1/v1'), isFalse);
      expect(BuiltinServiceConfig.isAllowedBaseUrl('https://example.com/v1'), isFalse);
    });
  });
}
