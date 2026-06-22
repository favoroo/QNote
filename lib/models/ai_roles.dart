import 'dart:convert';

class AiRoles {
  final String? assistant;
  final String? timelineOptimization;
  // 角色是否使用免费模型
  final bool assistantUseFreeModel;
  final bool timelineOptimizationUseFreeModel;

  const AiRoles({
    this.assistant,
    this.timelineOptimization,
    this.assistantUseFreeModel = false,
    this.timelineOptimizationUseFreeModel = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'assistant': assistant,
      'timelineOptimization': timelineOptimization,
      'assistantUseFreeModel': assistantUseFreeModel,
      'timelineOptimizationUseFreeModel': timelineOptimizationUseFreeModel,
    };
  }

  factory AiRoles.fromMap(Map<String, dynamic> map) {
    return AiRoles(
      assistant: map['assistant'] as String?,
      timelineOptimization: map['timelineOptimization'] as String?,
      assistantUseFreeModel: map['assistantUseFreeModel'] as bool? ?? false,
      timelineOptimizationUseFreeModel:
          map['timelineOptimizationUseFreeModel'] as bool? ?? false,
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiRoles fromJson(String json) =>
      AiRoles.fromMap(jsonDecode(json) as Map<String, dynamic>);

  AiRoles copyWith({
    String? assistant,
    String? timelineOptimization,
    bool? assistantUseFreeModel,
    bool? timelineOptimizationUseFreeModel,
  }) {
    return AiRoles(
      assistant: assistant ?? this.assistant,
      timelineOptimization: timelineOptimization ?? this.timelineOptimization,
      assistantUseFreeModel:
          assistantUseFreeModel ?? this.assistantUseFreeModel,
      timelineOptimizationUseFreeModel:
          timelineOptimizationUseFreeModel ??
              this.timelineOptimizationUseFreeModel,
    );
  }
}

class AiRoleSettings {
  final double temperature;
  final int maxTokens;
  final bool extractImages;

  const AiRoleSettings({
    this.temperature = 0.7,
    this.maxTokens = 2048,
    this.extractImages = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'temperature': temperature,
      'maxTokens': maxTokens,
      'extractImages': extractImages,
    };
  }

  factory AiRoleSettings.fromMap(Map<String, dynamic> map) {
    return AiRoleSettings(
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: map['maxTokens'] as int? ?? 2048,
      extractImages: map['extractImages'] as bool? ?? false,
    );
  }

  AiRoleSettings copyWith({
    double? temperature,
    int? maxTokens,
    bool? extractImages,
  }) {
    return AiRoleSettings(
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      extractImages: extractImages ?? this.extractImages,
    );
  }
}

class AiTemperatures {
  final AiRoleSettings assistant;
  final AiRoleSettings timelineOptimization;

  const AiTemperatures({
    this.assistant = const AiRoleSettings(),
    this.timelineOptimization = const AiRoleSettings(
      temperature: 0.01,
      maxTokens: 512,
    ),
  });

  Map<String, dynamic> toMap() {
    return {
      'assistant': assistant.toMap(),
      'timelineOptimization': timelineOptimization.toMap(),
    };
  }

  factory AiTemperatures.fromMap(Map<String, dynamic> map) {
    return AiTemperatures(
      assistant: map['assistant'] != null
          ? AiRoleSettings.fromMap(map['assistant'] as Map<String, dynamic>)
          : const AiRoleSettings(),
      timelineOptimization: map['timelineOptimization'] != null
          ? AiRoleSettings.fromMap(map['timelineOptimization'] as Map<String, dynamic>)
          : const AiRoleSettings(),
    );
  }

  AiTemperatures copyWith({
    AiRoleSettings? assistant,
    AiRoleSettings? timelineOptimization,
  }) {
    return AiTemperatures(
      assistant: assistant ?? this.assistant,
      timelineOptimization: timelineOptimization ?? this.timelineOptimization,
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiTemperatures fromJson(String json) =>
      AiTemperatures.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
