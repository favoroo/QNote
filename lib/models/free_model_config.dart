import 'dart:convert';

import 'package:qnote_flutter/core/utils/obfuscation_utils.dart';

/// 免费模型配置
///
/// 描述单个免费模型的配置信息，从远程清单加载。
class FreeModelConfig {
  final String id;
  final String displayName;
  final String provider;
  final String baseUrl;
  final String modelName;
  final String obfuscatedApiKey;
  final String authType;
  final int priority;

  const FreeModelConfig({
    required this.id,
    required this.displayName,
    required this.provider,
    required this.baseUrl,
    required this.modelName,
    required this.obfuscatedApiKey,
    this.authType = 'bearer',
    this.priority = 0,
  });

  /// 解混淆后的 apikey
  String get apiKey => ObfuscationUtils.deobfuscate(obfuscatedApiKey);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'displayName': displayName,
      'provider': provider,
      'baseUrl': baseUrl,
      'modelName': modelName,
      'obfuscatedApiKey': obfuscatedApiKey,
      'authType': authType,
      'priority': priority,
    };
  }

  factory FreeModelConfig.fromMap(Map<String, dynamic> map) {
    return FreeModelConfig(
      id: map['id'] as String? ?? '',
      displayName: map['displayName'] as String? ?? map['id'] as String? ?? '',
      provider: map['provider'] as String? ?? 'openai',
      baseUrl: map['baseUrl'] as String? ?? '',
      modelName: map['modelName'] as String? ?? '',
      obfuscatedApiKey: map['obfuscatedApiKey'] as String? ?? '',
      authType: map['authType'] as String? ?? 'bearer',
      priority: map['priority'] as int? ?? 0,
    );
  }

  FreeModelConfig copyWith({
    String? id,
    String? displayName,
    String? provider,
    String? baseUrl,
    String? modelName,
    String? obfuscatedApiKey,
    String? authType,
    int? priority,
  }) {
    return FreeModelConfig(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      modelName: modelName ?? this.modelName,
      obfuscatedApiKey: obfuscatedApiKey ?? this.obfuscatedApiKey,
      authType: authType ?? this.authType,
      priority: priority ?? this.priority,
    );
  }
}

/// 免费模型清单（远程配置文件结构）
class FreeModelsManifest {
  final String version;
  final DateTime? updatedAt;
  final List<FreeModelConfig> models;

  const FreeModelsManifest({
    this.version = '1.0',
    this.updatedAt,
    this.models = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'version': version,
      'updatedAt': updatedAt?.toIso8601String(),
      'models': models.map((m) => m.toMap()).toList(),
    };
  }

  factory FreeModelsManifest.fromMap(Map<String, dynamic> map) {
    return FreeModelsManifest(
      version: map['version'] as String? ?? '1.0',
      updatedAt: map['updatedAt'] != null
          ? DateTime.tryParse(map['updatedAt'] as String)
          : null,
      models: (map['models'] as List<dynamic>? ?? [])
          .map((m) => FreeModelConfig.fromMap(m as Map<String, dynamic>))
          .toList(),
    );
  }

  String toJson() => jsonEncode(toMap());

  static FreeModelsManifest fromJson(String json) =>
      FreeModelsManifest.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
