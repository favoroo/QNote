import 'package:flutter/material.dart';

/// 左下角记录按钮胶囊态文案的纯计算。
///
/// 按钮要同时表达「记的是哪一天」和「记的哪个时间段」，跨天区间最容易让人误读，
/// 所以这段拼接从 Widget 里抽出来单独可测。

/// 记录按钮胶囊态的两段式文案：可选日期角标 + 时间。
class TimelineSelectionLabel {
  const TimelineSelectionLabel({this.dayBadge, required this.time});

  /// 选中日相对今天的前后缀角标：`昨天` / `明天` / `10-08`；今天为 null。
  final String? dayBadge;

  /// 时间文案：`14:30`、`14:30–16:00`、`14:30–次日 02:00`。
  final String time;

  bool get hasBadge => dayBadge != null;
}

/// 生成记录按钮胶囊态文案。
///
/// [today] 必须是「今天」的零点，单独传入而不是用 `DateTime.now()`，
/// 这样跨零点与测试都能得到确定结果。
TimelineSelectionLabel buildTimelineSelectionLabel({
  required TimeOfDay startTime,
  TimeOfDay? endTime,
  required DateTime startDate,
  DateTime? endDate,
  required DateTime today,
}) {
  return TimelineSelectionLabel(
    dayBadge: _dayBadge(startDate, today),
    time: _timeRangeText(startTime: startTime, endTime: endTime, startDate: startDate, endDate: endDate),
  );
}

/// 相对今天的日期角标；今天不显示角标，其余给「昨天/明天」，再远给月-日。
String? _dayBadge(DateTime date, DateTime today) {
  final day = DateTime(date.year, date.month, date.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  final diff = day.difference(todayDay).inDays;
  if (diff == 0) {
    return null;
  }
  if (diff == -1) {
    return '昨天';
  }
  if (diff == 1) {
    return '明天';
  }
  return '${_twoDigits(day.month)}-${_twoDigits(day.day)}';
}

String _timeRangeText({
  required TimeOfDay startTime,
  required TimeOfDay? endTime,
  required DateTime startDate,
  required DateTime? endDate,
}) {
  final startText = _timeText(startTime);
  if (endTime == null) {
    return startText;
  }
  final endText = _timeText(endTime);
  final end = endDate ?? startDate;
  final dayDiff = DateTime(end.year, end.month, end.day)
      .difference(DateTime(startDate.year, startDate.month, startDate.day))
      .inDays;

  if (dayDiff == 0) {
    return '$startText–$endText';
  }
  // 跨天区间用「次日/前日」说人话，再远才回落到绝对月-日
  if (dayDiff == 1) {
    return '$startText–次日 $endText';
  }
  if (dayDiff == -1) {
    return '$startText–前日 $endText';
  }
  return '$startText–${_twoDigits(end.month)}-${_twoDigits(end.day)} $endText';
}

String _timeText(TimeOfDay time) => '${_twoDigits(time.hour)}:${_twoDigits(time.minute)}';

String _twoDigits(int value) => value.toString().padLeft(2, '0');
