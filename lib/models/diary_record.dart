import 'dart:convert';

class DiaryRecord {
  final String id;
  String title;
  DateTime time;
  DateTime? startTime;
  DateTime? endTime;
  List<String> tags;
  String displayTag;
  String content;
  Map<String, dynamic>? bodyState;
  List<String> photos;
  String colorMark;
  int mood;
  String weather;
  String? folderId;
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  DiaryRecord({
    required this.id,
    required this.title,
    required this.time,
    this.startTime,
    this.endTime,
    this.tags = const [],
    this.displayTag = '',
    this.content = '',
    this.bodyState,
    this.photos = const [],
    this.colorMark = '',
    this.mood = 3,
    this.weather = '',
    this.folderId,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'time': time.toIso8601String(),
      'start_time': startTime?.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'tags': jsonEncode(tags),
      'display_tag': displayTag,
      'content': content,
      'body_state': bodyState != null ? jsonEncode(bodyState) : null,
      'photos': jsonEncode(photos),
      'color_mark': colorMark,
      'mood': mood,
      'weather': weather,
      'folder_id': folderId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  factory DiaryRecord.fromMap(Map<String, dynamic> map) {
    return DiaryRecord(
      id: map['id'] as String,
      title: map['title'] as String,
      time: DateTime.parse(map['time'] as String),
      startTime: map['start_time'] != null
          ? DateTime.parse(map['start_time'] as String)
          : null,
      endTime: map['end_time'] != null
          ? DateTime.parse(map['end_time'] as String)
          : null,
      tags: map['tags'] != null
          ? List<String>.from(jsonDecode(map['tags'] as String) as List)
          : [],
      displayTag: map['display_tag'] as String? ?? '',
      content: map['content'] as String? ?? '',
      bodyState: map['body_state'] != null
          ? jsonDecode(map['body_state'] as String) as Map<String, dynamic>
          : null,
      photos: map['photos'] != null
          ? List<String>.from(jsonDecode(map['photos'] as String) as List)
          : [],
      colorMark: map['color_mark'] as String? ?? '',
      mood: map['mood'] as int? ?? 3,
      weather: map['weather'] as String? ?? '',
      folderId: map['folder_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
    );
  }

  DiaryRecord copyWith({
    String? id,
    String? title,
    DateTime? time,
    DateTime? startTime,
    DateTime? endTime,
    List<String>? tags,
    String? displayTag,
    String? content,
    Map<String, dynamic>? bodyState,
    List<String>? photos,
    String? colorMark,
    int? mood,
    String? weather,
    String? folderId,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
  }) {
    return DiaryRecord(
      id: id ?? this.id,
      title: title ?? this.title,
      time: time ?? this.time,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      tags: tags ?? this.tags,
      displayTag: displayTag ?? this.displayTag,
      content: content ?? this.content,
      bodyState: bodyState ?? this.bodyState,
      photos: photos ?? this.photos,
      colorMark: colorMark ?? this.colorMark,
      mood: mood ?? this.mood,
      weather: weather ?? this.weather,
      folderId: folderId ?? this.folderId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
