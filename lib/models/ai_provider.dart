import 'dart:convert';

import 'package:qnote_flutter/models/ai_model_ref.dart';

/// 厂商条目下的一个模型（已启用列表与扫描目录共用同一结构）
class AiProviderModel {
  /// 发给网关的模型 ID（如 `gpt-5.4-mini`）
  final String id;

  /// 展示名，默认与 [id] 相同，可保留旧配置的自定义名
  final String name;

  const AiProviderModel({required this.id, required this.name});

  /// 展示名缺省时回落到模型 ID，避免界面出现空标题
  factory AiProviderModel.of(String id, {String? name}) {
    final trimmed = (name ?? '').trim();
    return AiProviderModel(id: id, name: trimmed.isEmpty ? id : trimmed);
  }

  Map<String, dynamic> toMap() => {'id': id, 'name': name};

  factory AiProviderModel.fromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString();
    return AiProviderModel.of(id, name: map['name'] as String?);
  }

  static List<AiProviderModel> listFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <AiProviderModel>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final model = AiProviderModel.fromMap(Map<String, dynamic>.from(item));
        if (model.id.isEmpty || !seen.add(model.id)) continue;
        result.add(model);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<AiProviderModel> models) =>
      jsonEncode(models.map((m) => m.toMap()).toList());

  @override
  bool operator ==(Object other) =>
      other is AiProviderModel && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'AiProviderModel($id)';
}

/// 厂商条目：一个 URL + 一组 API Key + 一组已启用模型
///
/// 取代旧版「一个模型 = 一行 `ai_configs`」的模型级配置：密钥与地址属于厂商，
/// 模型只是厂商下的勾选项，因此「同一厂商多把 Key 轮询」与「扫描后按需启用多个
/// 模型」都落在同一条目上，与 CLIProxyAPI 的 provider + api-keys 语义一致。
class AiProvider {
  final String id;

  /// 指向 `lib/config/models.dart` 的厂商模板（自定义地址为 `custom`）
  final String? vendorId;

  /// 展示名，默认取厂商模板名
  final String name;

  /// 接口类型：`openai` | `gemini`
  final String providerType;

  final String baseUrl;

  /// API Key 池（至少一把；多把时发信层自动轮询）
  final List<String> apiKeys;

  /// 已启用模型（会出现在所有模型选择器里）
  final List<AiProviderModel> models;

  /// 最近一次「扫描模型」的结果缓存（含未启用的候选）
  final List<AiProviderModel> modelCatalog;

  final DateTime? catalogUpdatedAt;

  /// 未绑定角色的回落顺序上，默认厂商优先
  final bool isDefault;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AiProvider({
    required this.id,
    this.vendorId,
    required this.name,
    required this.providerType,
    required this.baseUrl,
    required this.apiKeys,
    this.models = const [],
    this.modelCatalog = const [],
    this.catalogUpdatedAt,
    this.isDefault = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 厂商下是否还有可用的「地址 + 密钥」组合
  bool get isUsable =>
      baseUrl.trim().isNotEmpty &&
      apiKeys.any((key) => key.trim().isNotEmpty) &&
      models.isNotEmpty;

  /// 首个已启用模型，作为未绑定角色时的默认选择
  AiProviderModel? get firstModel => models.isEmpty ? null : models.first;

  AiModelRef refFor(String modelName) =>
      AiModelRef(providerId: id, modelName: modelName);

  bool hasModel(String modelName) =>
      models.any((m) => m.id == modelName);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'vendor_id': vendorId,
      'name': name,
      'provider_type': providerType,
      'base_url': baseUrl,
      'api_keys': jsonEncode(apiKeys),
      'models': AiProviderModel.listToJson(models),
      'model_catalog': AiProviderModel.listToJson(modelCatalog),
      'catalog_updated_at': catalogUpdatedAt?.toIso8601String(),
      'is_default': isDefault ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AiProvider.fromMap(Map<String, dynamic> map) {
    return AiProvider(
      id: map['id'] as String,
      vendorId: map['vendor_id'] as String?,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? (map['name'] as String).trim()
          : ((map['vendor_id'] as String?) ?? '自定义'),
      providerType: (map['provider_type'] as String?) ?? 'openai',
      baseUrl: (map['base_url'] as String?) ?? '',
      apiKeys: _decodeKeys(map['api_keys']),
      models: AiProviderModel.listFromJson(map['models'] as String?),
      modelCatalog:
          AiProviderModel.listFromJson(map['model_catalog'] as String?),
      catalogUpdatedAt: _parseTime(map['catalog_updated_at'] as String?),
      isDefault: (map['is_default'] as int? ?? 0) == 1,
      createdAt: _parseTime(map['created_at'] as String?) ?? DateTime.now(),
      updatedAt: _parseTime(map['updated_at'] as String?) ?? DateTime.now(),
    );
  }

  AiProvider copyWith({
    String? id,
    Object? vendorId = _unset,
    String? name,
    String? providerType,
    String? baseUrl,
    List<String>? apiKeys,
    List<AiProviderModel>? models,
    List<AiProviderModel>? modelCatalog,
    Object? catalogUpdatedAt = _unset,
    bool? isDefault,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AiProvider(
      id: id ?? this.id,
      vendorId:
          identical(vendorId, _unset) ? this.vendorId : vendorId as String?,
      name: name ?? this.name,
      providerType: providerType ?? this.providerType,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKeys: apiKeys ?? this.apiKeys,
      models: models ?? this.models,
      modelCatalog: modelCatalog ?? this.modelCatalog,
      catalogUpdatedAt: identical(catalogUpdatedAt, _unset)
          ? this.catalogUpdatedAt
          : catalogUpdatedAt as DateTime?,
      isDefault: isDefault ?? this.isDefault,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const Object _unset = Object();

  static List<String> _decodeKeys(dynamic raw) {
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is! List) return const [];
      final keys = <String>[];
      for (final item in decoded) {
        final key = item?.toString().trim() ?? '';
        if (key.isNotEmpty && !keys.contains(key)) keys.add(key);
      }
      return keys;
    } catch (_) {
      return const [];
    }
  }

  static DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 旧备份/旧库里的 `ai_configs` 行 → 厂商条目（同 URL 归并密钥与模型）
  ///
  /// 迁移与「导入旧格式备份」共用这一条路径，保证两种来源得到一致结果。
  static List<AiProvider> fromLegacyConfigMaps(
    List<Map<String, dynamic>> configs,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    final order = <String>[];
    for (final map in configs) {
      final vendorId = (map['vendor_id'] as String?)?.trim() ?? '';
      final baseUrl = ((map['base_url'] as String?) ?? '').trim();
      final providerType = ((map['provider'] as String?) ?? 'openai').trim();
      final groupKey = '${vendorId.isEmpty ? 'custom' : vendorId}|$baseUrl|$providerType';
      if (!grouped.containsKey(groupKey)) {
        grouped[groupKey] = [];
        order.add(groupKey);
      }
      grouped[groupKey]!.add(map);
    }

    final providers = <AiProvider>[];
    for (final groupKey in order) {
      final rows = grouped[groupKey]!;
      final first = rows.first;
      final keys = <String>[];
      final models = <AiProviderModel>[];
      final modelIds = <String>{};
      var isDefault = false;
      DateTime? createdAt;
      DateTime? updatedAt;

      for (final row in rows) {
        final key = ((row['api_key'] as String?) ?? '').trim();
        if (key.isNotEmpty && !keys.contains(key)) keys.add(key);

        final modelName = ((row['model_name'] as String?) ?? '').trim();
        if (modelName.isNotEmpty && modelIds.add(modelName)) {
          models.add(AiProviderModel.of(modelName, name: row['name'] as String?));
        }

        if ((row['is_default'] as int? ?? 0) == 1) isDefault = true;
        final rowCreated = _parseTime(row['created_at'] as String?);
        if (rowCreated != null &&
            (createdAt == null || rowCreated.isBefore(createdAt))) {
          createdAt = rowCreated;
        }
        final rowUpdated = _parseTime(row['updated_at'] as String?);
        if (rowUpdated != null &&
            (updatedAt == null || rowUpdated.isAfter(updatedAt))) {
          updatedAt = rowUpdated;
        }
      }

      if (keys.isEmpty && models.isEmpty) continue;

      final vendorId = (first['vendor_id'] as String?)?.trim();
      providers.add(AiProvider(
        id: (first['id'] as String?) ?? '',
        vendorId: (vendorId == null || vendorId.isEmpty) ? 'custom' : vendorId,
        name: vendorId == null || vendorId.isEmpty ? '自定义服务' : vendorId,
        providerType: ((first['provider'] as String?) ?? 'openai'),
        baseUrl: ((first['base_url'] as String?) ?? '').trim(),
        apiKeys: keys,
        models: models,
        isDefault: isDefault,
        createdAt: createdAt ?? DateTime.now(),
        updatedAt: updatedAt ?? createdAt ?? DateTime.now(),
      ));
    }
    return providers;
  }
}