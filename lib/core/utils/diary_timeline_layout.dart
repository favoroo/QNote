/// 日记时间线的纯日期与布局计算。
///
/// 页面层负责读取 Provider、测量真实高度和驱动滚动；本文件只根据传入的日期、
/// 展开状态和记录展示时间推导文案与估算偏移，方便脱离 Widget 与数据库单独验证。
///
/// 约定：
/// - 所有「日期」都先归一到当天零点，时分秒不参与日期比较与天数差；
/// - 天数偏移按日历日计算（跨月、跨年、闰年 2 月 29 日均按自然日推进）；
/// - 估算函数不会裁剪窗口范围，调用方需自行保证目标日期已落在窗口内。
library;

/// 时间线中每一天占用的 item 数量：1 个日期分割栏 + 48 个半小时节点。
const int kDiaryTimelineItemsPerDay = 49;

/// 日期分割栏的固定高度。
const double kDiaryTimelineDividerHeight = 80.0;

/// 单个半小时节点的高度。
const double kDiaryTimelineNodeHeight = 48.0;

/// 展开日期中每条记录在滚动偏移估算时额外占用的平均高度。
const double kDiaryTimelineAverageRecordExtraHeight = 130.0;

/// ListView 顶部内边距，偏移估算的起始基准。
const double kDiaryTimelineTopPadding = 12.0;

/// 当天「当前时刻」专用指示节点的高度（非整点/半点时才出现）。
const double kDiaryTimelineCurrentTimeNodeHeight = 48.0;

const List<String> _weekDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 把任意时刻归一为当天零点。
///
/// 时间线只关心「哪一天」，记录时间、排序和窗口计算都基于零点日期，
/// 避免同一天不同时刻被误判为不同日期。
DateTime diaryDateOnly(DateTime value) {
  return DateTime(value.year, value.month, value.day);
}

/// 生成日期在记录分组中的键：`yyyy-MM-dd`。
///
/// 年份至少补足 4 位、月日补足 2 位，保证不同日期不会因位数不同产生歧义；
/// 时分秒被忽略，同一天的不同时刻得到同一个键。
String diaryDateKey(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// 计算 [date] 相对 [windowStartDate] 的日历天数偏移。
///
/// 两端都会先归一到零点，再用 UTC 日历日相减，跨月、跨年与闰年 2 月 29 日
/// 都按自然日计数，不受夏令时 23/25 小时日期影响。
///
/// [date] 早于窗口起点时返回负数；同一天任意时刻返回 0。
int diaryDayOffset(DateTime date, DateTime windowStartDate) {
  final target = diaryDateOnly(date);
  final start = diaryDateOnly(windowStartDate);
  return DateTime.utc(
    target.year,
    target.month,
    target.day,
  ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
}

/// 由窗口起点和天数偏移还原日期（零点）。
///
/// 使用 `DateTime` 构造器的日期归一化能力处理跨月、跨年与闰年，
/// [dayOffset] 可以为负，表示窗口起点之前的日期。
DateTime diaryDateForDayOffset(DateTime windowStartDate, int dayOffset) {
  final start = diaryDateOnly(windowStartDate);
  return DateTime(start.year, start.month, start.day + dayOffset);
}

/// 判断两个时刻是否落在同一个日历日。
///
/// 只比较年月日，忽略时分秒；用于时间线日期分组、选中态与「今天」判断。
bool isSameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// 判断 [date] 是否为 [today] 所在的日历日。
///
/// [today] 由调用方注入而不是内部读取 `DateTime.now()`，
/// 这样跨零点刷新与单元测试都能得到确定结果。
bool isTodayDate(DateTime date, DateTime today) {
  return isSameCalendarDay(date, today);
}

/// 判断日期是否默认展开。
///
/// 仅昨天、今天、明天默认展开，其余历史与未来日期默认折叠；
/// 用户手动覆盖的展开状态由页面层维护，不在这里处理。
bool isDiaryDateExpandedByDefault(DateTime date, DateTime today) {
  final yesterday = diaryDateForDayOffset(today, -1);
  final tomorrow = diaryDateForDayOffset(today, 1);
  return isSameCalendarDay(date, today) || isSameCalendarDay(date, yesterday) || isSameCalendarDay(date, tomorrow);
}

/// 顶部日期标题文案，例如 `26年11月11日 周三`。
///
/// 年份取后两位，月日补足两位；[date] 的时分秒不影响结果。
String formatDiaryDateTitle(DateTime date) {
  final year = date.year.toString().substring(2);
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final weekday = _weekDays[date.weekday - 1];
  return '$year年$month月$day日 $weekday';
}

/// 时间线日期分割栏文案，例如 `11月11日 周三`。
///
/// 不显示年份，月日不补零；跨年时仍按实际月日展示。
String formatDiaryDividerDate(DateTime date) {
  final weekday = _weekDays[date.weekday - 1];
  return '${date.month}月${date.day}日 $weekday';
}

/// 把时刻换算成时间线节点下标（0~47）。
///
/// 每 30 分钟一个节点：`00:00` 为 0，`00:30` 为 1，`23:30` 为 47；
/// 秒与毫秒被忽略，例如 `09:59` 仍落在 `09:30` 节点。
int diaryTimelineNodeIndex(DateTime time) {
  return time.hour * 2 + (time.minute >= 30 ? 1 : 0);
}

/// 拖动浮层中的记录预览文案。
///
/// 优先展示正文，正文为空时退回标题；两者都为空时按图片数量展示
/// `N 张图片`，没有图片则显示 `一条记录`。首尾空白会被裁剪。
String diaryDragPreviewText({required String content, required String title, required int photoCount}) {
  final trimmedContent = content.trim();
  if (trimmedContent.isNotEmpty) {
    return trimmedContent;
  }
  final trimmedTitle = title.trim();
  if (trimmedTitle.isNotEmpty) {
    return trimmedTitle;
  }
  return photoCount > 0 ? '$photoCount 张图片' : '一条记录';
}

/// 计算从 [startDate] 起 [daysCount] 天的总高度。
///
/// 每天固定包含一个分割栏；展开的日期再包含 48 个节点高度，
/// 以及 [recordCountForDate] 返回的记录数乘平均额外高度。
/// [recordCountForDate] 为空或某天没有记录时按 0 条处理；
/// [daysCount] 小于等于 0 时返回 0。
double calculateDiaryDaysHeight({
  required DateTime startDate,
  required int daysCount,
  required bool Function(DateTime date) isExpanded,
  int Function(DateTime date)? recordCountForDate,
  double dividerHeight = kDiaryTimelineDividerHeight,
  double nodeHeight = kDiaryTimelineNodeHeight,
  double averageRecordExtraHeight = kDiaryTimelineAverageRecordExtraHeight,
}) {
  var total = 0.0;
  for (var i = 0; i < daysCount; i++) {
    final date = diaryDateForDayOffset(startDate, i);
    total += dividerHeight;
    if (!isExpanded(date)) {
      continue;
    }
    total += (kDiaryTimelineItemsPerDay - 1) * nodeHeight;
    total += (recordCountForDate?.call(date) ?? 0) * averageRecordExtraHeight;
  }
  return total;
}

/// 按 item 下标估算列表滚动偏移。
///
/// [measuredHeights] 中已测量的 item 高度优先；未测量的分割栏按
/// [dividerHeight] 计，未测量的节点只在所属日期展开时按 [nodeHeight] 计，
/// 折叠日期的节点高度为 0。
///
/// [targetIndex] 小于等于 0 返回 0；超过当前窗口 item 数时仍按日期继续累加，
/// 不做窗口裁剪。[itemsPerDay] 必须为正数。
double estimateDiaryOffsetForIndex({
  required int targetIndex,
  required Map<int, double> measuredHeights,
  required DateTime windowStartDate,
  required bool Function(DateTime date) isExpanded,
  int itemsPerDay = kDiaryTimelineItemsPerDay,
  double dividerHeight = kDiaryTimelineDividerHeight,
  double nodeHeight = kDiaryTimelineNodeHeight,
}) {
  assert(itemsPerDay > 0, 'itemsPerDay 必须大于 0');
  var offset = 0.0;
  for (var i = 0; i < targetIndex; i++) {
    final measuredHeight = measuredHeights[i];
    if (measuredHeight != null) {
      offset += measuredHeight;
    } else if (i % itemsPerDay == 0) {
      offset += dividerHeight;
    } else {
      final dayOffset = i ~/ itemsPerDay;
      final date = diaryDateForDayOffset(windowStartDate, dayOffset);
      if (isExpanded(date)) {
        offset += nodeHeight;
      }
    }
  }
  return offset;
}

/// 估算滚动到 [targetTime] 所在节点需要的偏移。
///
/// [recordCountForDate] 用于展开日期的记录额外高度；[displayTimesForDate]
/// 只在目标日被调用，用于判断目标节点之前有哪些记录需要叠加额外高度。
/// 两者为空回调时按「无记录」处理。
///
/// 目标日之前（含）的每一天都会先累加一个分割栏；展开的更早日期按满节点
/// 与记录数累加，目标日按节点下标累加并在最后补节点半高用于居中。
/// 目标日正好是 [today] 且时刻不在整点/半点时，额外补当前时刻指示节点高度，
/// 与页面中的 `_CurrentTimeNode` 保持一致。
///
/// 不做窗口裁剪：目标早于 [windowStartDate] 时只返回顶部内边距；
/// 目标晚于窗口末尾时仍会继续累加沿途日期的分割栏。
double estimateDiaryOffsetForTimeWithRecords({
  required DateTime targetTime,
  required DateTime windowStartDate,
  required DateTime today,
  required bool Function(DateTime date) isExpanded,
  int Function(DateTime date)? recordCountForDate,
  Iterable<DateTime> Function(DateTime date)? displayTimesForDate,
  double topPadding = kDiaryTimelineTopPadding,
  double dividerHeight = kDiaryTimelineDividerHeight,
  double nodeHeight = kDiaryTimelineNodeHeight,
  double averageRecordExtraHeight = kDiaryTimelineAverageRecordExtraHeight,
  double currentTimeNodeHeight = kDiaryTimelineCurrentTimeNodeHeight,
}) {
  final targetDate = diaryDateOnly(targetTime);
  final dayOffset = diaryDayOffset(targetDate, windowStartDate);
  final nodeIndex = diaryTimelineNodeIndex(targetTime);

  var offset = topPadding;
  for (var d = 0; d <= dayOffset; d++) {
    final date = diaryDateForDayOffset(windowStartDate, d);
    offset += dividerHeight;

    if (!isExpanded(date)) {
      continue;
    }

    if (d < dayOffset) {
      offset += (kDiaryTimelineItemsPerDay - 1) * nodeHeight;
      offset += (recordCountForDate?.call(date) ?? 0) * averageRecordExtraHeight;
    } else {
      offset += nodeIndex * nodeHeight;
      final displayTimes = displayTimesForDate?.call(date) ?? const <DateTime>[];
      for (final displayTime in displayTimes) {
        if (diaryTimelineNodeIndex(displayTime) < nodeIndex) {
          offset += averageRecordExtraHeight;
        }
      }
      // 当天非整点/半点时，页面会插入专用当前时刻指示节点，估算需补其高度。
      if (isTodayDate(date, today) && !(targetTime.minute == 0 || targetTime.minute == 30)) {
        offset += currentTimeNodeHeight * 0.5;
      }
      // 对准当前节点中心。
      offset += nodeHeight * 0.5;
    }
  }
  return offset;
}
