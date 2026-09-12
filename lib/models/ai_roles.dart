import 'dart:convert';

class AiRoles {
  final String? assistant;
  final String? timelineOptimization;
  // 角色是否使用免费模型
  final bool assistantUseFreeModel;
  final bool timelineOptimizationUseFreeModel;
  // 角色具体使用的免费模型 ID (如 'sensenova-flash-lite', 'glm-5.2', 'deepseek-v4-flash')
  final String? assistantFreeModelId;
  final String? timelineOptimizationFreeModelId;
  // 小Q生图工具绑定的内置生图模型 ID (如 'gemini-3.1-flash-image', 'sensenova-u1.5-lite')
  final String? imageGenerationFreeModelId;

  const AiRoles({
    this.assistant,
    this.timelineOptimization,
    this.assistantUseFreeModel = false,
    this.timelineOptimizationUseFreeModel = false,
    this.assistantFreeModelId = 'gemini-3.5-flash-lite',
    this.timelineOptimizationFreeModelId = 'gemini-3.5-flash-lite',
    this.imageGenerationFreeModelId = 'gemini-3.1-flash-image',
  });

  Map<String, dynamic> toMap() {
    return {
      'assistant': assistant,
      'timelineOptimization': timelineOptimization,
      'assistantUseFreeModel': assistantUseFreeModel,
      'timelineOptimizationUseFreeModel': timelineOptimizationUseFreeModel,
      if (assistantFreeModelId != null) 'assistantFreeModelId': assistantFreeModelId,
      if (timelineOptimizationFreeModelId != null)
        'timelineOptimizationFreeModelId': timelineOptimizationFreeModelId,
      if (imageGenerationFreeModelId != null)
        'imageGenerationFreeModelId': imageGenerationFreeModelId,
    };
  }

  factory AiRoles.fromMap(Map<String, dynamic> map) {
    return AiRoles(
      assistant: map['assistant'] as String?,
      timelineOptimization: map['timelineOptimization'] as String?,
      assistantUseFreeModel: map['assistantUseFreeModel'] as bool? ?? false,
      timelineOptimizationUseFreeModel:
          map['timelineOptimizationUseFreeModel'] as bool? ?? false,
      assistantFreeModelId: map['assistantFreeModelId'] as String? ?? 'gemini-3.5-flash-lite',
      timelineOptimizationFreeModelId:
          map['timelineOptimizationFreeModelId'] as String? ?? 'gemini-3.5-flash-lite',
      imageGenerationFreeModelId:
          map['imageGenerationFreeModelId'] as String? ?? 'gemini-3.1-flash-image',
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiRoles fromJson(String json) =>
      AiRoles.fromMap(jsonDecode(json) as Map<String, dynamic>);

  /// 哨兵值：区分「未传参（保持原值）」与「显式传 null（清空绑定）」
  static const Object _unset = Object();

  /// 复制并修改角色绑定
  AiRoles copyWith({
    Object? assistant = _unset,
    Object? timelineOptimization = _unset,
    bool? assistantUseFreeModel,
    bool? timelineOptimizationUseFreeModel,
    Object? assistantFreeModelId = _unset,
    Object? timelineOptimizationFreeModelId = _unset,
    Object? imageGenerationFreeModelId = _unset,
  }) {
    return AiRoles(
      assistant: identical(assistant, _unset)
          ? this.assistant
          : assistant as String?,
      timelineOptimization: identical(timelineOptimization, _unset)
          ? this.timelineOptimization
          : timelineOptimization as String?,
      assistantUseFreeModel:
          assistantUseFreeModel ?? this.assistantUseFreeModel,
      timelineOptimizationUseFreeModel:
          timelineOptimizationUseFreeModel ??
              this.timelineOptimizationUseFreeModel,
      assistantFreeModelId: identical(assistantFreeModelId, _unset)
          ? this.assistantFreeModelId
          : assistantFreeModelId as String?,
      timelineOptimizationFreeModelId:
          identical(timelineOptimizationFreeModelId, _unset)
              ? this.timelineOptimizationFreeModelId
              : timelineOptimizationFreeModelId as String?,
      imageGenerationFreeModelId:
          identical(imageGenerationFreeModelId, _unset)
              ? this.imageGenerationFreeModelId
              : imageGenerationFreeModelId as String?,
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
