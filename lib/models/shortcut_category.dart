import 'dart:convert';
import 'package:qnote_flutter/models/shortcut_field.dart';

class ShortcutCategory {
  final String id;
  final String name;
  final List<ShortcutField> fields;

  ShortcutCategory({
    required this.id,
    required this.name,
    this.fields = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'fields': fields.map((f) => f.toMap()).toList(),
    };
  }

  factory ShortcutCategory.fromMap(Map<String, dynamic> map) {
    return ShortcutCategory(
      id: map['id'] as String,
      name: map['name'] as String,
      fields: (map['fields'] as List?)
              ?.map((f) => ShortcutField.fromMap(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  String toJson() => jsonEncode(toMap());

  static ShortcutCategory fromJson(String json) =>
      ShortcutCategory.fromMap(jsonDecode(json) as Map<String, dynamic>);

  ShortcutCategory copyWith({
    String? id,
    String? name,
    List<ShortcutField>? fields,
  }) {
    return ShortcutCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      fields: fields ?? this.fields,
    );
  }
}
