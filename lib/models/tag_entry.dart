import 'dart:convert';

class TagEntry {
  final String id;
  final String name;
  final Map<String, dynamic> fields;
  final String? time;

  const TagEntry({
    required this.id,
    required this.name,
    this.fields = const {},
    this.time,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'fields': fields.isNotEmpty ? jsonEncode(fields) : null,
      'time': time,
    };
  }

  factory TagEntry.fromMap(Map<String, dynamic> map) {
    return TagEntry(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      fields: map['fields'] != null
          ? (map['fields'] is String
              ? jsonDecode(map['fields'] as String) as Map<String, dynamic>
              : Map<String, dynamic>.from(map['fields'] as Map))
          : {},
      time: map['time'] as String?,
    );
  }

  TagEntry copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? fields,
    String? time,
  }) {
    return TagEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      fields: fields ?? this.fields,
      time: time ?? this.time,
    );
  }

  static List<TagEntry> listFromJson(String jsonStr) {
    if (jsonStr.isEmpty) return [];
    final list = jsonDecode(jsonStr) as List;
    return list.map((e) => TagEntry.fromMap(e as Map<String, dynamic>)).toList();
  }

  static String listToJson(List<TagEntry> entries) {
    return jsonEncode(entries.map((e) => e.toMap()).toList());
  }
}
