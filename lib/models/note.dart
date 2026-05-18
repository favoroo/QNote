import 'dart:convert';

class Note {
  final String id;
  String title;
  String content;
  String? folderId;
  String tags;
  bool isPinned;
  List<String> images;
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  Note({
    required this.id,
    required this.title,
    this.content = '',
    this.folderId,
    this.tags = '',
    this.isPinned = false,
    this.images = const [],
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'folder_id': folderId,
      'tags': tags,
      'is_pinned': isPinned ? 1 : 0,
      'images': jsonEncode(images),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as String,
      title: map['title'] as String,
      content: map['content'] as String? ?? '',
      folderId: map['folder_id'] as String?,
      tags: map['tags'] as String? ?? '',
      isPinned: (map['is_pinned'] as int? ?? 0) == 1,
      images: map['images'] != null
          ? List<String>.from(jsonDecode(map['images'] as String) as List)
          : [],
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
    );
  }

  Note copyWith({
    String? id,
    String? title,
    String? content,
    String? folderId,
    String? tags,
    bool? isPinned,
    List<String>? images,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      folderId: folderId ?? this.folderId,
      tags: tags ?? this.tags,
      isPinned: isPinned ?? this.isPinned,
      images: images ?? this.images,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
