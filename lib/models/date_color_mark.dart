class DateColorMark {
  final String id;
  DateTime date;
  String color;

  DateColorMark({
    required this.id,
    required this.date,
    required this.color,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String().split('T').first,
      'color': color,
    };
  }

  factory DateColorMark.fromMap(Map<String, dynamic> map) {
    return DateColorMark(
      id: map['id'] as String,
      date: DateTime.parse(map['date'] as String),
      color: map['color'] as String,
    );
  }

  DateColorMark copyWith({
    String? id,
    DateTime? date,
    String? color,
  }) {
    return DateColorMark(
      id: id ?? this.id,
      date: date ?? this.date,
      color: color ?? this.color,
    );
  }
}
