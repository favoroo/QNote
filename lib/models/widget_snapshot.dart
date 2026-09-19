import 'dart:convert';

/// 桌面小组件快照键约定（原生侧 `WidgetDatabase.snapshot()` 按同样的字符串读取，
/// 两端改动需同步）。
class WidgetSnapshotKeys {
  WidgetSnapshotKeys._();

  /// 今日文件夹内未完成待办数（date 为空，全局单行）
  static const String todoPendingToday = 'todo.pending_today';
}

/// 桌面小组件快照行：Dart 侧算好、原生侧只读渲染的中间结果。
///
/// 存在的理由是聚合口径全在 Dart（待办的「今日」是文件夹语义、日记归属日、
/// 收支合计带中文正则回退），原生裸 SQL 复现不出来。只把「确实需要 Dart 才能算」
/// 的量放进来；已是单表成型整数的（如 daily_scores、health_daily_metrics）
/// 由原生直查，不占快照。
class WidgetSnapshot {
  final String key;

  /// 按日聚合填 `YYYY-MM-DD`；与日期无关的高频小值用空串。
  final String date;
  final num? valueNum;
  final String? valueText;

  /// 多字段聚合的 JSON 载荷（如 `{"income":12,"expense":30}`）。
  final Map<String, dynamic>? payload;
  final DateTime updatedAt;

  WidgetSnapshot({
    required this.key,
    this.date = '',
    this.valueNum,
    this.valueText,
    this.payload,
    required this.updatedAt,
  });

  /// 表主键是 (key, date) 复合键，没有独立自然主键，按项目模型约定合成一个稳定 id。
  String get id => '$key|$date';

  /// 整数视图：原生组件渲染计数时直接用，避免自己处理 REAL → INT 转换。
  int? get intValue => valueNum?.toInt();

  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'date': date,
      'value_num': valueNum,
      'value_text': valueText,
      'payload': payload == null ? null : jsonEncode(payload),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory WidgetSnapshot.fromMap(Map<String, dynamic> map) {
    final rawPayload = map['payload'];
    Map<String, dynamic>? decoded;
    if (rawPayload is String && rawPayload.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawPayload);
        if (parsed is Map) {
          decoded = parsed.cast<String, dynamic>();
        }
      } catch (_) {
        // 载荷被写坏时按无载荷处理，计数类字段仍可用
      }
    }
    return WidgetSnapshot(
      key: map['key'] as String,
      date: map['date'] as String? ?? '',
      valueNum: map['value_num'] as num?,
      valueText: map['value_text'] as String?,
      payload: decoded,
      updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  WidgetSnapshot copyWith({
    String? key,
    String? date,
    num? valueNum,
    String? valueText,
    Map<String, dynamic>? payload,
    DateTime? updatedAt,
  }) {
    return WidgetSnapshot(
      key: key ?? this.key,
      date: date ?? this.date,
      valueNum: valueNum ?? this.valueNum,
      valueText: valueText ?? this.valueText,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
