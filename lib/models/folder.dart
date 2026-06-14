class Folder {
  final String id;
  final String name;
  final String? parentId;
  final String type;
  final int sortOrder;
  final bool isExpanded;
  final DateTime createdAt;
  final DateTime updatedAt;

  Folder({
    required this.id,
    required this.name,
    this.parentId,
    this.type = 'note',
    this.sortOrder = 0,
    this.isExpanded = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'parent_id': parentId,
      'type': type,
      'sort_order': sortOrder,
      'is_expanded': isExpanded ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Folder.fromMap(Map<String, dynamic> map) {
    return Folder(
      id: map['id'] as String,
      name: map['name'] as String,
      parentId: map['parent_id'] as String?,
      type: map['type'] as String? ?? 'note',
      sortOrder: map['sort_order'] as int? ?? 0,
      isExpanded: (map['is_expanded'] as int? ?? 1) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  Folder copyWith({
    String? id,
    String? name,
    String? parentId,
    String? type,
    int? sortOrder,
    bool? isExpanded,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearParentId = false,
  }) {
    return Folder(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: clearParentId ? null : (parentId ?? this.parentId),
      type: type ?? this.type,
      sortOrder: sortOrder ?? this.sortOrder,
      isExpanded: isExpanded ?? this.isExpanded,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
