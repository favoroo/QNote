import 'dart:convert';

/// 固定事件模板
/// 用于快速记录每日固定事件，如"8点到12点上班"
class FixedEventTemplate {
  final String id;
  String name;           // 事件名称，如"上班"
  String startTime;      // 开始时间，格式 "HH:mm"，如 "08:00"
  String endTime;        // 结束时间，格式 "HH:mm"；时间点模式下为空串 ""
  bool isTimePoint;      // 是否为时间点模式（true：只有单个时间点，无结束时间）
  String? content;       // 默认备注内容
  List<String> tags;     // 关联标签 ID 列表
  /// 每个标签下预设的字段值：key = tagId, value = {fieldKey: fieldValue}
  Map<String, Map<String, dynamic>> tagFields;
  int sortOrder;         // 排序顺序
  bool isEnabled;        // 是否启用
  DateTime createdAt;
  DateTime updatedAt;

  FixedEventTemplate({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    this.isTimePoint = false,
    this.content,
    this.tags = const [],
    this.tagFields = const {},
    this.sortOrder = 0,
    this.isEnabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'start_time': startTime,
      'end_time': endTime,
      'is_time_point': isTimePoint ? 1 : 0,
      'content': content ?? '',
      'tags': jsonEncode(tags),
      'tag_fields': jsonEncode(tagFields),
      'sort_order': sortOrder,
      'is_enabled': isEnabled ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory FixedEventTemplate.fromMap(Map<String, dynamic> map) {
    final tags = map['tags'] != null
        ? List<String>.from(jsonDecode(map['tags'] as String) as List)
        : <String>[];
    Map<String, dynamic> tagFields = {};
    if (map['tag_fields'] != null && (map['tag_fields'] as String).isNotEmpty) {
      try {
        tagFields = jsonDecode(map['tag_fields'] as String) as Map<String, dynamic>;
      } catch (_) {}
    }
    return FixedEventTemplate(
      id: map['id'] as String,
      name: map['name'] as String,
      startTime: map['start_time'] as String,
      endTime: map['end_time'] as String? ?? '',
      isTimePoint: (map['is_time_point'] as int?) == 1,
      content: map['content'] as String?,
      tags: tags,
      tagFields: tagFields.map((k, v) => MapEntry(k, v is Map<String, dynamic> ? v : {})),
      sortOrder: map['sort_order'] as int? ?? 0,
      isEnabled: (map['is_enabled'] as int? ?? 1) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  FixedEventTemplate copyWith({
    String? id,
    String? name,
    String? startTime,
    String? endTime,
    bool? isTimePoint,
    String? content,
    List<String>? tags,
    Map<String, Map<String, dynamic>>? tagFields,
    int? sortOrder,
    bool? isEnabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return FixedEventTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isTimePoint: isTimePoint ?? this.isTimePoint,
      content: content ?? this.content,
      tags: tags ?? this.tags,
      tagFields: tagFields ?? this.tagFields,
      sortOrder: sortOrder ?? this.sortOrder,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 解析开始时间为 TimeOfDay 的 hour 和 minute
  int get startHour {
    final parts = startTime.split(':');
    return int.tryParse(parts[0]) ?? 0;
  }

  int get startMinute {
    final parts = startTime.split(':');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  /// 解析结束时间为 TimeOfDay 的 hour 和 minute
  int get endHour {
    final parts = endTime.split(':');
    return int.tryParse(parts[0]) ?? 0;
  }

  int get endMinute {
    final parts = endTime.split(':');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  /// 格式化显示时间：时间点模式返回 "08:00"，时间段返回 "08:00 - 12:00"
  String get formattedTimeRange {
    if (isTimePoint) return startTime;
    return '$startTime - $endTime';
  }
}