class AiConfig {
  final String id;
  final String name;
  final String provider;
  final String modelName;
  final String apiKey;
  final String baseUrl;
  final bool isDefault;
  final String? vendorId;
  final DateTime createdAt;
  final DateTime updatedAt;

  AiConfig({
    required this.id,
    required this.name,
    required this.provider,
    required this.modelName,
    required this.apiKey,
    required this.baseUrl,
    this.isDefault = false,
    this.vendorId,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'provider': provider,
      'model_name': modelName,
      'api_key': apiKey,
      'base_url': baseUrl,
      'is_default': isDefault ? 1 : 0,
      'vendor_id': vendorId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AiConfig.fromMap(Map<String, dynamic> map) {
    return AiConfig(
      id: map['id'] as String,
      name: map['name'] as String? ?? '',
      provider: map['provider'] as String,
      modelName: map['model_name'] as String,
      apiKey: map['api_key'] as String,
      baseUrl: map['base_url'] as String,
      isDefault: (map['is_default'] as int? ?? 0) == 1,
      vendorId: map['vendor_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  AiConfig copyWith({
    String? id,
    String? name,
    String? provider,
    String? modelName,
    String? apiKey,
    String? baseUrl,
    bool? isDefault,
    String? vendorId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AiConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      modelName: modelName ?? this.modelName,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      isDefault: isDefault ?? this.isDefault,
      vendorId: vendorId ?? this.vendorId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
