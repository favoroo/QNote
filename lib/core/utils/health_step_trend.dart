import 'dart:math' as math;

/// 步数趋势柱状图的汇总粒度。
enum StepTrendUnit { day, month }

/// 趋势图里一根柱子所代表的时间桶。
class StepTrendBucket {
  const StepTrendBucket({
    required this.unit,
    required this.start,
    required this.end,
    required this.value,
    required this.observedDays,
    this.showYear = false,
  });

  /// 该桶所属的汇总粒度
  final StepTrendUnit unit;

  /// 桶起始日（零点）
  final DateTime start;

  /// 桶结束日（零点），按天粒度时与 [start] 相同
  final DateTime end;

  /// 柱高：按天粒度是当日步数，按月粒度是桶内「有记录日」的日均步数
  final double value;

  /// 桶内同步到数据的天数，0 表示这段时间没有记录
  final int observedDays;

  /// 是否需要在 X 轴标签上带年份（首个桶与跨年边界）
  final bool showYear;

  bool get hasData => observedDays > 0;

  /// X 轴刻度文案
  String get axisLabel {
    if (unit == StepTrendUnit.day) {
      return '${start.month}/${start.day}';
    }
    return showYear ? '${start.year % 100}年${start.month}月' : '${start.month}月';
  }

  /// X 轴刻度文案的估算占位宽度，用于抽稀
  double get labelWidth => unit == StepTrendUnit.day ? 30 : (showYear ? 34 : 24);

  /// 浮层里的时间范围文案
  String get rangeLabel {
    if (unit == StepTrendUnit.day) {
      return '${start.year}/${start.month}/${start.day}';
    }
    return '${start.year}/${start.month}/${start.day}–${end.month}/${end.day}';
  }
}

/// 趋势图构建结果。
class StepTrend {
  const StepTrend({required this.unit, required this.buckets});

  final StepTrendUnit unit;
  final List<StepTrendBucket> buckets;

  /// 卡片副标题，说明柱子的口径（当日值还是日均值）
  String get caption => unit == StepTrendUnit.day ? '按天' : '按月 · 日均';

  /// 单个 X 轴标签的占位宽度，用于刻度抽稀
  double get labelWidth => unit == StepTrendUnit.day ? 30 : 24;
}

/// 超过这个天数仍按天出柱就会挤成一团，改为按月汇总。
const int monthlyModeMinDays = 62;

/// 把逐日步数按区间长度聚合成柱子。
///
/// [stepsByDay] 的 key 必须是归一到零点的日期；区间内缺数据的日期按空桶处理，
/// 这样未同步的日期不会被折叠掉、柱子也不会冒充「连续达标」。
StepTrend buildStepTrend({
  required DateTime startDate,
  required DateTime endDate,
  required Map<DateTime, int> stepsByDay,
}) {
  final from = DateTime(startDate.year, startDate.month, startDate.day);
  final to = DateTime(endDate.year, endDate.month, endDate.day);
  final spanDays = to.difference(from).inDays + 1;

  if (spanDays <= monthlyModeMinDays) {
    final buckets = <StepTrendBucket>[];
    for (var day = from; !day.isAfter(to); day = DateTime(day.year, day.month, day.day + 1)) {
      final steps = stepsByDay[day];
      buckets.add(
        StepTrendBucket(
          unit: StepTrendUnit.day,
          start: day,
          end: day,
          value: (steps ?? 0).toDouble(),
          observedDays: steps == null ? 0 : 1,
        ),
      );
    }
    return StepTrend(unit: StepTrendUnit.day, buckets: buckets);
  }

  // 长区间按自然月切桶，柱高取月内日均步数，与日/周视图保持同一量纲，
  // 才能继续用「是否达到每日目标」这一套配色判断。
  final buckets = <StepTrendBucket>[];
  var monthStart = DateTime(from.year, from.month, 1);
  final lastMonthStart = DateTime(to.year, to.month, 1);
  while (!monthStart.isAfter(lastMonthStart)) {
    final nextMonth = DateTime(monthStart.year, monthStart.month + 1, 1);
    final monthEnd = DateTime(nextMonth.year, nextMonth.month, nextMonth.day - 1);
    final windowStart = monthStart.isBefore(from) ? from : monthStart;
    final windowEnd = monthEnd.isAfter(to) ? to : monthEnd;

    var sum = 0;
    var observed = 0;
    for (var day = windowStart; !day.isAfter(windowEnd); day = DateTime(day.year, day.month, day.day + 1)) {
      final steps = stepsByDay[day];
      if (steps != null) {
        sum += steps;
        observed++;
      }
    }

    buckets.add(
      StepTrendBucket(
        unit: StepTrendUnit.month,
        start: windowStart,
        end: windowEnd,
        value: observed > 0 ? sum / observed : 0,
        observedDays: observed,
        // 跨年的区间要在首桶和 1 月标出年份，否则两个「9月」分不清
        showYear: buckets.isEmpty || windowStart.month == 1,
      ),
    );
    monthStart = nextMonth;
  }

  return StepTrend(unit: StepTrendUnit.month, buckets: buckets);
}

/// 计算 X 轴标签的抽稀间隔：每 [interval] 个桶出一个标签，避免标签互相压字。
int stepAxisLabelInterval({
  required int bucketCount,
  required double plotWidth,
  required double minLabelWidth,
}) {
  if (bucketCount <= 1 || plotWidth <= 0 || minLabelWidth <= 0) {
    return 1;
  }
  final fits = math.max(1, (plotWidth / minLabelWidth).floor());
  if (fits >= bucketCount) {
    return 1;
  }
  return (bucketCount / fits).ceil();
}
