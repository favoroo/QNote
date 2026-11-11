import 'package:qnote_flutter/models/diary_record.dart';

/// 时间线卡片拖动调时的纯计算。
///
/// 页面层只负责把手指位移换算成「内容坐标系」下的像素位移（含列表滚动补偿），
/// 本文件决定吸附粒度、日界限制与平移后的时间字段；这样拖拽手感可以脱离
/// 数据库与 UI 单独验证。

/// 时间线每 30 分钟一个时间节点。
const int kTimelineNodeMinutes = 30;

/// 拖动时时间变化的最小粒度（分钟）。
const int kTimelineDragSnapMinutes = 5;

/// 按节点高度换算拖动灵敏度（像素/分钟）。
///
/// 节点高度越大，手指移动同样距离对应的时间变化越小，拖动越精细。
double timelineDragPixelsPerMinute(double nodeHeight) {
  if (nodeHeight <= 0) {
    return 1;
  }
  return nodeHeight / kTimelineNodeMinutes;
}

/// 把内容坐标系的竖直位移换算成吸附后的整体平移分钟数。
///
/// [contentDeltaPx] 为正表示向下拖（时间变晚），为负表示向上拖（时间变早）。
int resolveTimelineDragDeltaMinutes({
  required double contentDeltaPx,
  required double pixelsPerMinute,
  int snapMinutes = kTimelineDragSnapMinutes,
}) {
  final safePixelsPerMinute = pixelsPerMinute <= 0 ? 1.0 : pixelsPerMinute;
  final grid = snapMinutes <= 0 ? 1 : snapMinutes;
  final rawMinutes = contentDeltaPx / safePixelsPerMinute;
  return (rawMinutes / grid).round() * grid;
}

/// 一条记录整体平移后的时间字段。
///
/// 只做整条平移、不改时长：有开始/结束时间的记录（睡眠、运动等）保持区间长度。
class TimelineTimeShift {
  const TimelineTimeShift({
    required this.deltaMinutes,
    required this.time,
    required this.startTime,
    required this.endTime,
  });

  /// 相对原时间的平移分钟数。
  final int deltaMinutes;

  /// 平移后的 `time` 字段。
  final DateTime time;

  /// 平移后的开始时间（无区间记录为 null）。
  final DateTime? startTime;

  /// 平移后的结束时间（无区间记录为 null）。
  final DateTime? endTime;

  bool get isChanged => deltaMinutes != 0;
}

/// 计算拖动后的时间平移结果。
///
/// 约束：开始时间必须留在原日期内，避免一拖就跨天导致卡片从当前日期消失；
/// 需要跨天时仍可通过编辑页调整。日界处允许时间落在 00:00 / 23:59。
TimelineTimeShift resolveTimelineTimeShift({
  required DiaryRecord record,
  required double contentDeltaPx,
  required double pixelsPerMinute,
  int snapMinutes = kTimelineDragSnapMinutes,
}) {
  final anchor = record.startTime ?? record.time;
  var delta = resolveTimelineDragDeltaMinutes(
    contentDeltaPx: contentDeltaPx,
    pixelsPerMinute: pixelsPerMinute,
    snapMinutes: snapMinutes,
  );

  final dayStart = DateTime(anchor.year, anchor.month, anchor.day);
  final dayEnd = dayStart.add(const Duration(days: 1)).subtract(const Duration(minutes: 1));
  final minDelta = dayStart.difference(anchor).inMinutes;
  final maxDelta = dayEnd.difference(anchor).inMinutes;
  delta = delta.clamp(minDelta, maxDelta);

  final shift = Duration(minutes: delta);
  return TimelineTimeShift(
    deltaMinutes: delta,
    time: record.time.add(shift),
    startTime: record.startTime?.add(shift),
    endTime: record.endTime?.add(shift),
  );
}

/// 拖动浮层与 Toast 共用的时间标签。
///
/// 单点记录显示 `HH:mm`；同一天的时间段显示 `HH:mm–HH:mm`；
/// 跨天结束时间以「次日」前缀提示，避免用户误以为时间倒流。
String formatTimelineDragTimeLabel(DateTime start, {DateTime? end}) {
  final startText = '${_twoDigits(start.hour)}:${_twoDigits(start.minute)}';
  if (end == null) {
    return startText;
  }
  final endText = '${_twoDigits(end.hour)}:${_twoDigits(end.minute)}';
  final startDay = DateTime(start.year, start.month, start.day);
  final endDay = DateTime(end.year, end.month, end.day);
  final dayDiff = endDay.difference(startDay).inDays;

  if (dayDiff == 0) {
    return '$startText–$endText';
  }
  if (dayDiff == 1) {
    return '$startText–次日 $endText';
  }
  final month = _twoDigits(end.month);
  final day = _twoDigits(end.day);
  return '$startText–$month-$day $endText';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
