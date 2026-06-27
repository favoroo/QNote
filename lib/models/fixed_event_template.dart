import 'dart:convert';

/// 时间段
class TimePeriod {
  final String startTime; // 开始时间，格式 "HH:mm"，如 "08:30"
  final String endTime;   // 结束时间，格式 "HH:mm"；时间点模式下为空串 ""

  TimePeriod({required this.startTime, required this.endTime});

  Map<String, dynamic> toMap() => {
        'start_time': startTime,
        'end_time': endTime,
      };

  factory TimePeriod.fromMap(Map<String, dynamic> map) => TimePeriod(
        startTime: map['start_time'] as String? ?? '08:00',
        endTime: map['end_time'] as String? ?? '',
      );
}

/// 固定事件模板
/// 用于快速记录每日固定事件，如"8点到12点上班"
class FixedEventTemplate {
  final String id;
  final String name;           // 事件名称，如"上班"
  final String startTime;      // 开始时间，格式 "HH:mm"，如 "08:00"
  final String endTime;        // 结束时间，格式 "HH:mm"；时间点模式下为空串 ""
  final bool isTimePoint;      // 是否为时间点模式（true：只有单个时间点，无结束时间）
  final String? content;       // 默认备注内容
  final List<String> tags;     // 关联标签 ID 列表
  /// 每个标签下预设的字段值：key = tagId, value = {fieldKey: fieldValue}
  final Map<String, Map<String, dynamic>> tagFields;
  final int sortOrder;         // 排序顺序
  final bool isEnabled;        // 是否启用
  final List<TimePeriod> timePeriods; // 支持多个时间段/时间点
  final DateTime createdAt;
  final DateTime updatedAt;

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
    List<TimePeriod>? timePeriods,
    required this.createdAt,
    required this.updatedAt,
  }) : this.timePeriods = timePeriods ?? [TimePeriod(startTime: startTime, endTime: endTime)];

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'start_time': timePeriods.isNotEmpty ? timePeriods.first.startTime : startTime,
      'end_time': timePeriods.isNotEmpty ? timePeriods.first.endTime : endTime,
      'is_time_point': isTimePoint ? 1 : 0,
      'content': content ?? '',
      'tags': jsonEncode(tags),
      'tag_fields': jsonEncode(tagFields),
      'sort_order': sortOrder,
      'is_enabled': isEnabled ? 1 : 0,
      'time_periods': jsonEncode(timePeriods.map((p) => p.toMap()).toList()),
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

    final sTime = map['start_time'] as String? ?? '08:00';
    final eTime = map['end_time'] as String? ?? '';

    List<TimePeriod> periods = [];
    if (map['time_periods'] != null && (map['time_periods'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(map['time_periods'] as String) as List;
        periods = decoded.map((p) => TimePeriod.fromMap(p as Map<String, dynamic>)).toList();
      } catch (_) {}
    }
    if (periods.isEmpty) {
      periods = [TimePeriod(startTime: sTime, endTime: eTime)];
    }

    return FixedEventTemplate(
      id: map['id'] as String,
      name: map['name'] as String,
      startTime: sTime,
      endTime: eTime,
      isTimePoint: (map['is_time_point'] as int?) == 1,
      content: map['content'] as String?,
      tags: tags,
      tagFields: tagFields.map((k, v) => MapEntry(k, v is Map<String, dynamic> ? v : {})),
      sortOrder: map['sort_order'] as int? ?? 0,
      isEnabled: (map['is_enabled'] as int? ?? 1) == 1,
      timePeriods: periods,
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
    List<TimePeriod>? timePeriods,
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
      timePeriods: timePeriods ?? this.timePeriods,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 解析开始时间为 TimeOfDay 的 hour 和 minute (取第一个时间段的)
  int get startHour {
    final first = timePeriods.isNotEmpty ? timePeriods.first : TimePeriod(startTime: startTime, endTime: endTime);
    final parts = first.startTime.split(':');
    return int.tryParse(parts[0]) ?? 0;
  }

  int get startMinute {
    final first = timePeriods.isNotEmpty ? timePeriods.first : TimePeriod(startTime: startTime, endTime: endTime);
    final parts = first.startTime.split(':');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  /// 解析结束时间为 TimeOfDay 的 hour 和 minute (取第一个时间段的)
  int get endHour {
    final first = timePeriods.isNotEmpty ? timePeriods.first : TimePeriod(startTime: startTime, endTime: endTime);
    final parts = first.endTime.split(':');
    return int.tryParse(parts[0]) ?? 0;
  }

  int get endMinute {
    final first = timePeriods.isNotEmpty ? timePeriods.first : TimePeriod(startTime: startTime, endTime: endTime);
    final parts = first.endTime.split(':');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  /// 格式化显示时间：时间点模式返回如 "08:00, 13:30"，时间段返回如 "08:30-12:00, 13:30-18:00"
  String get formattedTimeRange {
    if (timePeriods.isEmpty) {
      if (isTimePoint) return startTime;
      return '$startTime - $endTime';
    }
    return timePeriods.map((p) {
      if (isTimePoint || p.endTime.isEmpty) return p.startTime;
      return '${p.startTime}-${p.endTime}';
    }).join(', ');
  }
}