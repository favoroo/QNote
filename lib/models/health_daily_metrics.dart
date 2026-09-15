import 'dart:convert';

/// 单日健康综合汇总指标模型
class HealthDailyMetrics {
  final String date; // YYYY-MM-DD
  final int steps;
  final double distanceMeters;
  final double calories;
  final int activeMinutes;
  final int standingCount; // 站立次数
  
  // 睡眠相关 (单位：分钟)
  final int sleepDurationMinutes;
  final int deepSleepMinutes;
  final int lightSleepMinutes;
  final int remSleepMinutes;
  final int awakeMinutes;
  final String? sleepStartTime; // ISO8601 或 HH:mm
  final String? sleepEndTime;
  final int? sleepScore;

  // 生理指标
  final int? avgHeartRate;
  final int? maxHeartRate;
  final int? minHeartRate;
  final int? restingHeartRate;
  final int? avgSpo2;
  final int? minSpo2;
  final int? avgStress;
  final int? maxStress;

  // 详细时间序列采样点（JSON 字符串存储：[{"t":1710000000,"v":72},...]）
  final String heartRateSamplesJson;
  final String spo2SamplesJson;
  final String stressSamplesJson;
  final String sleepStagesJson;

  final String source; // 来源，例如 'mi_fitness'
  final DateTime updatedAt;

  const HealthDailyMetrics({
    required this.date,
    this.steps = 0,
    this.distanceMeters = 0.0,
    this.calories = 0.0,
    this.activeMinutes = 0,
    this.standingCount = 0,
    this.sleepDurationMinutes = 0,
    this.deepSleepMinutes = 0,
    this.lightSleepMinutes = 0,
    this.remSleepMinutes = 0,
    this.awakeMinutes = 0,
    this.sleepStartTime,
    this.sleepEndTime,
    this.sleepScore,
    this.avgHeartRate,
    this.maxHeartRate,
    this.minHeartRate,
    this.restingHeartRate,
    this.avgSpo2,
    this.minSpo2,
    this.avgStress,
    this.maxStress,
    this.heartRateSamplesJson = '[]',
    this.spo2SamplesJson = '[]',
    this.stressSamplesJson = '[]',
    this.sleepStagesJson = '[]',
    this.source = 'mi_fitness',
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'date': date,
      'steps': steps,
      'distance_meters': distanceMeters,
      'calories': calories,
      'active_minutes': activeMinutes,
      'standing_count': standingCount,
      'sleep_duration_minutes': sleepDurationMinutes,
      'deep_sleep_minutes': deepSleepMinutes,
      'light_sleep_minutes': lightSleepMinutes,
      'rem_sleep_minutes': remSleepMinutes,
      'awake_minutes': awakeMinutes,
      'sleep_start_time': sleepStartTime,
      'sleep_end_time': sleepEndTime,
      'sleep_score': sleepScore,
      'avg_heart_rate': avgHeartRate,
      'max_heart_rate': maxHeartRate,
      'min_heart_rate': minHeartRate,
      'resting_heart_rate': restingHeartRate,
      'avg_spo2': avgSpo2,
      'min_spo2': minSpo2,
      'avg_stress': avgStress,
      'max_stress': maxStress,
      'heart_rate_samples_json': heartRateSamplesJson,
      'spo2_samples_json': spo2SamplesJson,
      'stress_samples_json': stressSamplesJson,
      'sleep_stages_json': sleepStagesJson,
      'source': source,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory HealthDailyMetrics.fromMap(Map<String, dynamic> map) {
    return HealthDailyMetrics(
      date: map['date'] as String,
      steps: (map['steps'] as num?)?.toInt() ?? 0,
      distanceMeters: (map['distance_meters'] as num?)?.toDouble() ?? 0.0,
      calories: (map['calories'] as num?)?.toDouble() ?? 0.0,
      activeMinutes: (map['active_minutes'] as num?)?.toInt() ?? 0,
      standingCount: (map['standing_count'] as num?)?.toInt() ?? 0,
      sleepDurationMinutes: (map['sleep_duration_minutes'] as num?)?.toInt() ?? 0,
      deepSleepMinutes: (map['deep_sleep_minutes'] as num?)?.toInt() ?? 0,
      lightSleepMinutes: (map['light_sleep_minutes'] as num?)?.toInt() ?? 0,
      remSleepMinutes: (map['rem_sleep_minutes'] as num?)?.toInt() ?? 0,
      awakeMinutes: (map['awake_minutes'] as num?)?.toInt() ?? 0,
      sleepStartTime: map['sleep_start_time'] as String?,
      sleepEndTime: map['sleep_end_time'] as String?,
      sleepScore: (map['sleep_score'] as num?)?.toInt(),
      avgHeartRate: (map['avg_heart_rate'] as num?)?.toInt(),
      maxHeartRate: (map['max_heart_rate'] as num?)?.toInt(),
      minHeartRate: (map['min_heart_rate'] as num?)?.toInt(),
      restingHeartRate: (map['resting_heart_rate'] as num?)?.toInt(),
      avgSpo2: (map['avg_spo2'] as num?)?.toInt(),
      minSpo2: (map['min_spo2'] as num?)?.toInt(),
      avgStress: (map['avg_stress'] as num?)?.toInt(),
      maxStress: (map['max_stress'] as num?)?.toInt(),
      heartRateSamplesJson: map['heart_rate_samples_json'] as String? ?? '[]',
      spo2SamplesJson: map['spo2_samples_json'] as String? ?? '[]',
      stressSamplesJson: map['stress_samples_json'] as String? ?? '[]',
      sleepStagesJson: map['sleep_stages_json'] as String? ?? '[]',
      source: map['source'] as String? ?? 'mi_fitness',
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  HealthDailyMetrics copyWith({
    String? date,
    int? steps,
    double? distanceMeters,
    double? calories,
    int? activeMinutes,
    int? standingCount,
    int? sleepDurationMinutes,
    int? deepSleepMinutes,
    int? lightSleepMinutes,
    int? remSleepMinutes,
    int? awakeMinutes,
    String? sleepStartTime,
    String? sleepEndTime,
    int? sleepScore,
    int? avgHeartRate,
    int? maxHeartRate,
    int? minHeartRate,
    int? restingHeartRate,
    int? avgSpo2,
    int? minSpo2,
    int? avgStress,
    int? maxStress,
    String? heartRateSamplesJson,
    String? spo2SamplesJson,
    String? stressSamplesJson,
    String? sleepStagesJson,
    String? source,
    DateTime? updatedAt,
  }) {
    return HealthDailyMetrics(
      date: date ?? this.date,
      steps: steps ?? this.steps,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      calories: calories ?? this.calories,
      activeMinutes: activeMinutes ?? this.activeMinutes,
      standingCount: standingCount ?? this.standingCount,
      sleepDurationMinutes: sleepDurationMinutes ?? this.sleepDurationMinutes,
      deepSleepMinutes: deepSleepMinutes ?? this.deepSleepMinutes,
      lightSleepMinutes: lightSleepMinutes ?? this.lightSleepMinutes,
      remSleepMinutes: remSleepMinutes ?? this.remSleepMinutes,
      awakeMinutes: awakeMinutes ?? this.awakeMinutes,
      sleepStartTime: sleepStartTime ?? this.sleepStartTime,
      sleepEndTime: sleepEndTime ?? this.sleepEndTime,
      sleepScore: sleepScore ?? this.sleepScore,
      avgHeartRate: avgHeartRate ?? this.avgHeartRate,
      maxHeartRate: maxHeartRate ?? this.maxHeartRate,
      minHeartRate: minHeartRate ?? this.minHeartRate,
      restingHeartRate: restingHeartRate ?? this.restingHeartRate,
      avgSpo2: avgSpo2 ?? this.avgSpo2,
      minSpo2: minSpo2 ?? this.minSpo2,
      avgStress: avgStress ?? this.avgStress,
      maxStress: maxStress ?? this.maxStress,
      heartRateSamplesJson: heartRateSamplesJson ?? this.heartRateSamplesJson,
      spo2SamplesJson: spo2SamplesJson ?? this.spo2SamplesJson,
      stressSamplesJson: stressSamplesJson ?? this.stressSamplesJson,
      sleepStagesJson: sleepStagesJson ?? this.sleepStagesJson,
      source: source ?? this.source,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 辅助解析心率采样点列表
  List<Map<String, dynamic>> parseHeartRateSamples() {
    try {
      final decoded = jsonDecode(heartRateSamplesJson);
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return const [];
  }
}
