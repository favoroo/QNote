import 'dart:convert';

class ShortcutField {
  final String id;
  String label;
  String type;
  List<String> options;

  ShortcutField({
    required this.id,
    required this.label,
    required this.type,
    this.options = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'type': type,
      'options': options,
    };
  }

  factory ShortcutField.fromMap(Map<String, dynamic> map) {
    return ShortcutField(
      id: map['id'] as String,
      label: map['label'] as String,
      type: map['type'] as String,
      options: List<String>.from(map['options'] as List? ?? []),
    );
  }

  String toJson() => jsonEncode(toMap());

  static ShortcutField fromJson(String json) =>
      ShortcutField.fromMap(jsonDecode(json) as Map<String, dynamic>);

  ShortcutField copyWith({
    String? id,
    String? label,
    String? type,
    List<String>? options,
  }) {
    return ShortcutField(
      id: id ?? this.id,
      label: label ?? this.label,
      type: type ?? this.type,
      options: options ?? this.options,
    );
  }
}
