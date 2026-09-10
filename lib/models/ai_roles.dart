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
    this.maxTokens = 4096,
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
      maxTokens: map['maxTokens'] as int? ?? 4096,
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
    this.assistant = const AiRoleSettings(maxTokens: 4096),
    this.timelineOptimization = const AiRoleSettings(
      temperature: 0.01,
      // 推理模型（如 SenseNova、DeepSeek-R1）需要足够 token 预算给思维链 + JSON 输出
      // 512 不够，会被 reasoning 耗尽导致 finish_reason: "length" 截断
      maxTokens: 2048,
      extractImages: true,
    ),
  });

  AiTemperatures copyWith({
    AiRoleSettings? assistant,
    AiRoleSettings? timelineOptimization,
  }) {
    return AiTemperatures(
      assistant: assistant ?? this.assistant,
      timelineOptimization:
          timelineOptimization ?? this.timelineOptimization,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'assistant': assistant.toMap(),
      'timelineOptimization': timelineOptimization.toMap(),
    };
  }

  factory AiTemperatures.fromMap(Map<String, dynamic> map) {
    var assistantSettings = map['assistant'] != null
        ? AiRoleSettings.fromMap(map['assistant'] as Map<String, dynamic>)
        : const AiRoleSettings(maxTokens: 4096);
    // 提问助手场景（长文分析/思维链）将老用户的 2048 预算平滑提升至 4096，避免截断
    if (assistantSettings.maxTokens < 4096) {
      assistantSettings = assistantSettings.copyWith(maxTokens: 4096);
    }

    final timelineSettings = map['timelineOptimization'] != null
        ? AiRoleSettings.fromMap(map['timelineOptimization'] as Map<String, dynamic>)
        : const AiRoleSettings(
            temperature: 0.01,
            maxTokens: 2048,
            extractImages: true,
          );

    return AiTemperatures(
      assistant: assistantSettings,
      timelineOptimization: timelineSettings,
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiTemperatures fromJson(String json) =>
      AiTemperatures.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
