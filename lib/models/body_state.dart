class BodyState {
  final String id;
  DateTime date;
  int energy;
  int mood;
  int sleepQuality;
  int exercise;
  double? weight;
  String note;
  DateTime createdAt;
  DateTime updatedAt;

  BodyState({
    required this.id,
    required this.date,
    this.energy = 3,
    this.mood = 3,
    this.sleepQuality = 3,
    this.exercise = 0,
    this.weight,
    this.note = '',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'energy': energy,
      'mood': mood,
      'sleep_quality': sleepQuality,
      'exercise': exercise,
      'weight': weight,
      'note': note,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory BodyState.fromMap(Map<String, dynamic> map) {
    return BodyState(
      id: map['id'] as String,
      date: DateTime.parse(map['date'] as String),
      energy: map['energy'] as int? ?? 3,
      mood: map['mood'] as int? ?? 3,
      sleepQuality: map['sleep_quality'] as int? ?? 3,
      exercise: map['exercise'] as int? ?? 0,
      weight: (map['weight'] as num?)?.toDouble(),
      note: map['note'] as String? ?? '',
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  BodyState copyWith({
    String? id,
    DateTime? date,
    int? energy,
    int? mood,
    int? sleepQuality,
    int? exercise,
    double? weight,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return BodyState(
      id: id ?? this.id,
      date: date ?? this.date,
      energy: energy ?? this.energy,
      mood: mood ?? this.mood,
      sleepQuality: sleepQuality ?? this.sleepQuality,
      exercise: exercise ?? this.exercise,
      weight: weight ?? this.weight,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
