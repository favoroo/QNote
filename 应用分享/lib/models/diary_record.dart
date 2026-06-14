import 'dart:convert';
import 'package:qnote_flutter/models/tag_entry.dart';

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
  List<TagEntry> tagEntries;
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
    this.tagEntries = const [],
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
      'tag_entries': tagEntries.isNotEmpty ? TagEntry.listToJson(tagEntries) : null,
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
    List<TagEntry> tagEntries = [];
    if (map['tag_entries'] != null && (map['tag_entries'] as String).isNotEmpty) {
      tagEntries = TagEntry.listFromJson(map['tag_entries'] as String);
    }

    final tags = map['tags'] != null
        ? List<String>.from(jsonDecode(map['tags'] as String) as List)
        : <String>[];
    final displayTag = map['display_tag'] as String? ?? '';
    final bodyState = map['body_state'] != null
        ? jsonDecode(map['body_state'] as String) as Map<String, dynamic>
        : null;

    if (tagEntries.isEmpty && tags.isNotEmpty) {
      tagEntries = tags.map((tag) {
        return TagEntry(
          id: tag,
          name: tag,
          fields: (tag == displayTag && bodyState != null) ? Map<String, dynamic>.from(bodyState) : {},
        );
      }).toList();
    }

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
      tags: tags,
      displayTag: displayTag,
      content: map['content'] as String? ?? '',
      bodyState: bodyState,
      tagEntries: tagEntries,
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
    List<TagEntry>? tagEntries,
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
      tagEntries: tagEntries ?? this.tagEntries,
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

  DateTime getEffectiveDate() {
    if (startTime == null || endTime == null) {
      return DateTime(time.year, time.month, time.day);
    }

    final start = startTime!;
    final end = endTime!;

    if (start.year == end.year && start.month == end.month && start.day == end.day) {
      return DateTime(start.year, start.month, start.day);
    }

    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);

    final startDayEnd = startDay.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));
    final endDayStart = endDay;

    final durationInStartDay = startDayEnd.difference(start).inMilliseconds;
    final durationInEndDay = end.difference(endDayStart).inMilliseconds;

    if (durationInEndDay >= durationInStartDay) {
      return endDay;
    } else {
      return startDay;
    }
  }

  bool belongsToDate(DateTime date) {
    final targetDate = DateTime(date.year, date.month, date.day);
    final effectiveDate = getEffectiveDate();
    return effectiveDate.year == targetDate.year &&
           effectiveDate.month == targetDate.month &&
           effectiveDate.day == targetDate.day;
  }

  bool intersectsDateRange(DateTime startDate, DateTime endDate) {
    if (startTime != null && endTime != null) {
      final recordStart = DateTime(startTime!.year, startTime!.month, startTime!.day);
      final recordEnd = DateTime(endTime!.year, endTime!.month, endTime!.day);
      final rangeStart = DateTime(startDate.year, startDate.month, startDate.day);
      final rangeEnd = DateTime(endDate.year, endDate.month, endDate.day);

      return !recordEnd.isBefore(rangeStart) && !recordStart.isAfter(rangeEnd);
    } else {
      final recordDate = DateTime(time.year, time.month, time.day);
      final rangeStart = DateTime(startDate.year, startDate.month, startDate.day);
      final rangeEnd = DateTime(endDate.year, endDate.month, endDate.day);

      return !recordDate.isBefore(rangeStart) && !recordDate.isAfter(rangeEnd);
    }
  }

  DateTime getDisplayTime() {
    if (startTime == null || endTime == null) {
      return time;
    }

    final start = startTime!;
    final end = endTime!;

    // 如果在同一天，返回结束时间 (endTime)
    if (start.year == end.year && start.month == end.month && start.day == end.day) {
      return end;
    }

    // 如果跨天，根据 getEffectiveDate() 判定归属日期
    final effectiveDate = getEffectiveDate();
    final endDay = DateTime(end.year, end.month, end.day);

    if (effectiveDate.year == endDay.year &&
        effectiveDate.month == endDay.month &&
        effectiveDate.day == endDay.day) {
      // 如果归属为后一天，返回结束时间 (endTime)
      return end;
    } else {
      // 如果归属为前一天，返回前一天的 23:30 (即 11 点半)
      return DateTime(start.year, start.month, start.day, 23, 30);
    }
  }
}
