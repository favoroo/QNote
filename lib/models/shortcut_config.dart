import 'dart:convert';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';

class ShortcutConfig {
  final String id;
  String name;
  bool hasPopup;
  List<ShortcutField> fields;
  List<ShortcutCategory>? categories;
  String? imageExtractionPrompt;
  int sortOrder;
  DateTime createdAt;
  DateTime updatedAt;

  ShortcutConfig({
    required this.id,
    required this.name,
    this.hasPopup = false,
    this.fields = const [],
    this.categories,
    this.imageExtractionPrompt,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'prompt': '',
      'icon': '',
      'has_popup': hasPopup ? 1 : 0,
      'fields': jsonEncode(fields.map((f) => f.toMap()).toList()),
      'categories': categories != null
          ? jsonEncode(categories!.map((c) => c.toMap()).toList())
          : null,
      'image_extraction_prompt': imageExtractionPrompt,
      'sort_order': sortOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory ShortcutConfig.fromMap(Map<String, dynamic> map) {
    return ShortcutConfig(
      id: map['id'] as String,
      name: map['name'] as String,
      hasPopup: (map['has_popup'] as int? ?? 0) == 1,
      fields: map['fields'] != null
          ? (jsonDecode(map['fields'] as String) as List)
              .map((f) => ShortcutField.fromMap(f as Map<String, dynamic>))
              .toList()
          : [],
      categories: map['categories'] != null
          ? (jsonDecode(map['categories'] as String) as List)
              .map((c) => ShortcutCategory.fromMap(c as Map<String, dynamic>))
              .toList()
          : null,
      imageExtractionPrompt: map['image_extraction_prompt'] as String?,
      sortOrder: map['sort_order'] as int? ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  ShortcutConfig copyWith({
    String? id,
    String? name,
    bool? hasPopup,
    List<ShortcutField>? fields,
    List<ShortcutCategory>? categories,
    String? imageExtractionPrompt,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ShortcutConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      hasPopup: hasPopup ?? this.hasPopup,
      fields: fields ?? this.fields,
      categories: categories ?? this.categories,
      imageExtractionPrompt: imageExtractionPrompt ?? this.imageExtractionPrompt,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
