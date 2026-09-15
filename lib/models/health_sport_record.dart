import 'dart:convert';

/// 单次运动记录模型（对应跑步、骑行、徒步、健身等）
class HealthSportRecord {
  final String id;
  final String sid; // 小米云端全局唯一运动记录 sid
  final String category; // running, cycling, walking, workout 等
  final String title; // 户外跑步、户外骑行、自由训练等
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;
  final double distanceMeters;
  final double calories;
  final double? avgPace; // 秒/公里
  final double? maxPace;
  final double? avgSpeed; // km/h
  final int? avgHeartRate;
  final int? maxHeartRate;
  final int? steps;
  final int? avgCadence; // 步频
  final String? trackGeoJson; // 轨迹（若有）
  final String detailJson; // 原始详细数据
  final String source; // 'mi_fitness'
  final DateTime createdAt;

  const HealthSportRecord({
    required this.id,
    required this.sid,
    required this.category,
    required this.title,
    required this.startTime,
    required this.endTime,
    this.durationSeconds = 0,
    this.distanceMeters = 0.0,
    this.calories = 0.0,
    this.avgPace,
    this.maxPace,
    this.avgSpeed,
    this.avgHeartRate,
    this.maxHeartRate,
    this.steps,
    this.avgCadence,
    this.trackGeoJson,
    this.detailJson = '{}',
    this.source = 'mi_fitness',
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sid': sid,
      'category': category,
      'title': title,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime.toIso8601String(),
      'duration_seconds': durationSeconds,
      'distance_meters': distanceMeters,
      'calories': calories,
      'avg_pace': avgPace,
      'max_pace': maxPace,
      'avg_speed': avgSpeed,
      'avg_heart_rate': avgHeartRate,
      'max_heart_rate': maxHeartRate,
      'steps': steps,
      'avg_cadence': avgCadence,
      'track_geo_json': trackGeoJson,
      'detail_json': detailJson,
      'source': source,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory HealthSportRecord.fromMap(Map<String, dynamic> map) {
    return HealthSportRecord(
      id: map['id'] as String,
      sid: map['sid'] as String? ?? map['id'] as String,
      category: map['category'] as String? ?? 'workout',
      title: map['title'] as String? ?? '运动',
      startTime: DateTime.parse(map['start_time'] as String),
      endTime: DateTime.parse(map['end_time'] as String),
      durationSeconds: (map['duration_seconds'] as num?)?.toInt() ?? 0,
      distanceMeters: (map['distance_meters'] as num?)?.toDouble() ?? 0.0,
      calories: (map['calories'] as num?)?.toDouble() ?? 0.0,
      avgPace: (map['avg_pace'] as num?)?.toDouble(),
      maxPace: (map['max_pace'] as num?)?.toDouble(),
      avgSpeed: (map['avg_speed'] as num?)?.toDouble(),
      avgHeartRate: (map['avg_heart_rate'] as num?)?.toInt(),
      maxHeartRate: (map['max_heart_rate'] as num?)?.toInt(),
      steps: (map['steps'] as num?)?.toInt(),
      avgCadence: (map['avg_cadence'] as num?)?.toInt(),
      trackGeoJson: map['track_geo_json'] as String?,
      detailJson: map['detail_json'] as String? ?? '{}',
      source: map['source'] as String? ?? 'mi_fitness',
      createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  HealthSportRecord copyWith({
    String? id,
    String? sid,
    String? category,
    String? title,
    DateTime? startTime,
    DateTime? endTime,
    int? durationSeconds,
    double? distanceMeters,
    double? calories,
    double? avgPace,
    double? maxPace,
    double? avgSpeed,
    int? avgHeartRate,
    int? maxHeartRate,
    int? steps,
    int? avgCadence,
    String? trackGeoJson,
    String? detailJson,
    String? source,
    DateTime? createdAt,
  }) {
    return HealthSportRecord(
      id: id ?? this.id,
      sid: sid ?? this.sid,
      category: category ?? this.category,
      title: title ?? this.title,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      calories: calories ?? this.calories,
      avgPace: avgPace ?? this.avgPace,
      maxPace: maxPace ?? this.maxPace,
      avgSpeed: avgSpeed ?? this.avgSpeed,
      avgHeartRate: avgHeartRate ?? this.avgHeartRate,
      maxHeartRate: maxHeartRate ?? this.maxHeartRate,
      steps: steps ?? this.steps,
      avgCadence: avgCadence ?? this.avgCadence,
      trackGeoJson: trackGeoJson ?? this.trackGeoJson,
      detailJson: detailJson ?? this.detailJson,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> parseDetail() {
    try {
      final decoded = jsonDecode(detailJson);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return const {};
  }
}
