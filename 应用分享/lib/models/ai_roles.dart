import 'dart:convert';

class AiRoles {
  final String? imageExtraction;
  final String? assistant;
  final String? timelineOptimization;

  const AiRoles({
    this.imageExtraction,
    this.assistant,
    this.timelineOptimization,
  });

  Map<String, dynamic> toMap() {
    return {
      'imageExtraction': imageExtraction,
      'assistant': assistant,
      'timelineOptimization': timelineOptimization,
    };
  }

  factory AiRoles.fromMap(Map<String, dynamic> map) {
    return AiRoles(
      imageExtraction: map['imageExtraction'] as String?,
      assistant: map['assistant'] as String?,
      timelineOptimization: map['timelineOptimization'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiRoles fromJson(String json) =>
      AiRoles.fromMap(jsonDecode(json) as Map<String, dynamic>);

  AiRoles copyWith({
    String? imageExtraction,
    String? assistant,
    String? timelineOptimization,
  }) {
    return AiRoles(
      imageExtraction: imageExtraction ?? this.imageExtraction,
      assistant: assistant ?? this.assistant,
      timelineOptimization: timelineOptimization ?? this.timelineOptimization,
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

  AiRoleSettings copyWith({double? temperature, int? maxTokens, bool? extractImages}) {
    return AiRoleSettings(
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      extractImages: extractImages ?? this.extractImages,
    );
  }
}

class AiTemperatures {
  final AiRoleSettings imageExtraction;
  final AiRoleSettings assistant;
  final AiRoleSettings timelineOptimization;

  const AiTemperatures({
    this.imageExtraction = const AiRoleSettings(),
    this.assistant = const AiRoleSettings(),
    this.timelineOptimization = const AiRoleSettings(),
  });

  Map<String, dynamic> toMap() {
    return {
      'imageExtraction': imageExtraction.toMap(),
      'assistant': assistant.toMap(),
      'timelineOptimization': timelineOptimization.toMap(),
    };
  }

  factory AiTemperatures.fromMap(Map<String, dynamic> map) {
    return AiTemperatures(
      imageExtraction: map['imageExtraction'] != null
          ? AiRoleSettings.fromMap(
              map['imageExtraction'] as Map<String, dynamic>)
          : const AiRoleSettings(),
      assistant: map['assistant'] != null
          ? AiRoleSettings.fromMap(
              map['assistant'] as Map<String, dynamic>)
          : const AiRoleSettings(),
      timelineOptimization: map['timelineOptimization'] != null
          ? AiRoleSettings.fromMap(
              map['timelineOptimization'] as Map<String, dynamic>)
          : const AiRoleSettings(),
    );
  }

  static AiRoleSettings _legacyToSettings(dynamic value) {
    if (value is num) {
      return AiRoleSettings(temperature: value.toDouble());
    }
    return const AiRoleSettings();
  }

  AiTemperatures copyWith({
    AiRoleSettings? imageExtraction,
    AiRoleSettings? assistant,
    AiRoleSettings? timelineOptimization,
  }) {
    return AiTemperatures(
      imageExtraction: imageExtraction ?? this.imageExtraction,
      assistant: assistant ?? this.assistant,
      timelineOptimization: timelineOptimization ?? this.timelineOptimization,
    );
  }

  String toJson() => jsonEncode(toMap());

  static AiTemperatures fromJson(String json) =>
      AiTemperatures.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
