class WeightRecord {
  final String id;
  double weight;
  DateTime time;

  WeightRecord({
    required this.id,
    required this.weight,
    required this.time,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'weight': weight,
      'time': time.toIso8601String(),
    };
  }

  factory WeightRecord.fromMap(Map<String, dynamic> map) {
    return WeightRecord(
      id: map['id'] as String,
      weight: (map['weight'] as num).toDouble(),
      time: DateTime.parse(map['time'] as String),
    );
  }

  WeightRecord copyWith({
    String? id,
    double? weight,
    DateTime? time,
  }) {
    return WeightRecord(
      id: id ?? this.id,
      weight: weight ?? this.weight,
      time: time ?? this.time,
    );
  }
}
