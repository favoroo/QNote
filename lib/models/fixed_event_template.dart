import 'dart:convert';

/// 固定事件模板
/// 用于快速记录每日固定事件，如"8点到12点上班"
class FixedEventTemplate {
  final String id;
  String name;           // 事件名称，如"上班"
  String startTime;      // 开始时间，格式 "HH:mm"，如 "08:00"
  String endTime;        // 结束时间，格式 "HH:mm"，如 "12:00"
  String? content;       // 默认备注内容
  List<String> tags;     // 关联标签
  int sortOrder;         // 排序顺序
  bool isEnabled;        // 是否启用
  DateTime createdAt;
  DateTime updatedAt;

  FixedEventTemplate({
    required this.id,
    required this.name,
    required this.startTime,
    required this.endTime,
    this.content,
    this.tags = const [],
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
      'content': content ?? '',
      'tags': jsonEncode(tags),
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
    return FixedEventTemplate(
      id: map['id'] as String,
      name: map['name'] as String,
      startTime: map['start_time'] as String,
      endTime: map['end_time'] as String,
      content: map['content'] as String?,
      tags: tags,
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
    String? content,
    List<String>? tags,
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
      content: content ?? this.content,
      tags: tags ?? this.tags,
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

  /// 格式化显示时间段，如 "08:00 - 12:00"
  String get formattedTimeRange {
    return '$startTime - $endTime';
  }
}