import 'dart:convert';

class ShortcutField {
  final String id;
  final String label;
  final String type;
  final List<String> options;
  final bool allowCustom;

  ShortcutField({
    required this.id,
    required this.label,
    required this.type,
    this.options = const [],
    this.allowCustom = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'type': type,
      'options': options,
      'allowCustom': allowCustom,
    };
  }

  factory ShortcutField.fromMap(Map<String, dynamic> map) {
    return ShortcutField(
      id: map['id'] as String,
      label: map['label'] as String,
      type: map['type'] as String,
      options: List<String>.from(map['options'] as List? ?? []),
      allowCustom: map['allowCustom'] as bool? ?? false,
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
    bool? allowCustom,
  }) {
    return ShortcutField(
      id: id ?? this.id,
      label: label ?? this.label,
      type: type ?? this.type,
      options: options ?? this.options,
      allowCustom: allowCustom ?? this.allowCustom,
    );
  }
}
