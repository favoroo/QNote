import 'dart:convert';

class DailyScore {
  final String id;
  final DateTime date;                    // 评分日期
  final int totalScore;                   // 总分 (0-100)
  final Map<String, int> dimensionScores; // 各维度分数
  final String summary;                   // AI 生成的总结
  final String suggestions;               // AI 生成的建议
  final int recordCount;                  // 当天记录数量
  final DateTime createdAt;               // 评分时间
  final DateTime updatedAt;               // 更新时间

  DailyScore({
    required this.id,
    required this.date,
    required this.totalScore,
    required this.dimensionScores,
    required this.summary,
    required this.suggestions,
    required this.recordCount,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String().split('T').first,
      'total_score': totalScore,
      'dimension_scores': jsonEncode(dimensionScores),
      'summary': summary,
      'suggestions': suggestions,
      'record_count': recordCount,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory DailyScore.fromMap(Map<String, dynamic> map) {
    Map<String, int> parsedDimensionScores = {};
    final rawScores = map['dimension_scores'];
    if (rawScores is String) {
      final decoded = jsonDecode(rawScores) as Map;
      parsedDimensionScores = decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } else if (rawScores is Map) {
      parsedDimensionScores = rawScores.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    }

    return DailyScore(
      id: map['id'] as String,
      date: DateTime.parse(map['date'] as String),
      totalScore: map['total_score'] as int,
      dimensionScores: parsedDimensionScores,
      summary: map['summary'] as String? ?? '',
      suggestions: map['suggestions'] as String? ?? '',
      recordCount: map['record_count'] as int? ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  DailyScore copyWith({
    String? id,
    DateTime? date,
    int? totalScore,
    Map<String, int>? dimensionScores,
    String? summary,
    String? suggestions,
    int? recordCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DailyScore(
      id: id ?? this.id,
      date: date ?? this.date,
      totalScore: totalScore ?? this.totalScore,
      dimensionScores: dimensionScores ?? this.dimensionScores,
      summary: summary ?? this.summary,
      suggestions: suggestions ?? this.suggestions,
      recordCount: recordCount ?? this.recordCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
