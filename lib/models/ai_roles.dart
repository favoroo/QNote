import 'dart:convert';

import 'package:qnote_flutter/models/ai_model_ref.dart';

/// 角色 → 模型绑定
///
/// 每个角色绑定一个 [AiModelRef]（厂商条目 + 模型名）；未绑定时由
/// `AiRoleService` 回落到默认厂商的首个已启用模型。旧版「是否使用内置免费模型 /
/// 内置模型 id / 配置 id」字段已随内置模型一并下线：读取旧 JSON 时这些键会被
/// 忽略，裸配置 id 因无法解析为 [AiModelRef] 自然归位到「未绑定」。
class AiRoles {
  /// 小Q 对话模型
  final AiModelRef? assistant;

  /// 时间线/日记 AI 提取模型
  final AiModelRef? timelineOptimization;

  /// 小Q 生图工具使用的模型（需支持 OpenAI 兼容 images/generations）
  final AiModelRef? imageGeneration;

  const AiRoles({
    this.assistant,
    this.timelineOptimization,
    this.imageGeneration,
  });

  Map<String, dynamic> toMap() {
    return {
      if (assistant != null) 'assistant': assistant!.encode(),
      if (timelineOptimization != null)
        'timelineOptimization': timelineOptimization!.encode(),
      if (imageGeneration != null) 'imageGeneration': imageGeneration!.encode(),
    };
  }

  factory AiRoles.fromMap(Map<String, dynamic> map) {
    return AiRoles(
      assistant: AiModelRef.tryParse(map['assistant'] as String?),
      timelineOptimization:
          AiModelRef.tryParse(map['timelineOptimization'] as String?),
      imageGeneration: AiModelRef.tryParse(map['imageGeneration'] as String?),
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiRoles fromJson(String json) =>
      AiRoles.fromMap(jsonDecode(json) as Map<String, dynamic>);

  /// 哨兵值：区分「未传参（保持原值）」与「显式传 null（清空绑定）」
  static const Object _unset = Object();

  AiRoles copyWith({
    Object? assistant = _unset,
    Object? timelineOptimization = _unset,
    Object? imageGeneration = _unset,
  }) {
    return AiRoles(
      assistant:
          identical(assistant, _unset) ? this.assistant : assistant as AiModelRef?,
      timelineOptimization: identical(timelineOptimization, _unset)
          ? this.timelineOptimization
          : timelineOptimization as AiModelRef?,
      imageGeneration: identical(imageGeneration, _unset)
          ? this.imageGeneration
          : imageGeneration as AiModelRef?,
    );
  }
}

class AiRoleSettings {
  final double temperature;
  final int maxTokens;
  final bool extractImages;

  const AiRoleSettings({
    this.temperature = 0.7,
    // 小Q多步 ReAct 循环 + 工具结果回传，4096 容易 finish_reason: length 截断
    this.maxTokens = 32000,
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
      maxTokens: map['maxTokens'] as int? ?? 32000,
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
    this.assistant = const AiRoleSettings(maxTokens: 32000),
    this.timelineOptimization = const AiRoleSettings(
      temperature: 0.01,
      // 推理模型（带思维链的模型）需要足够 token 预算给思维链 + JSON 输出
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
        : const AiRoleSettings(maxTokens: 32000);
    // 提问助手场景（长文分析/思维链）将老用户的 4096 预算平滑提升至 32000，避免截断
    if (assistantSettings.maxTokens < 32000) {
      assistantSettings = assistantSettings.copyWith(maxTokens: 32000);
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