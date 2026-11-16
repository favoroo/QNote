import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/utils/mermaid_gantt.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 原生甘特视图：固定左侧任务列 + 可横向滚动的时间轴 + 日/周/月缩放。
///
/// Mermaid 自带的 gantt SVG 在手机上会把任务名和时间轴绑在一起滚走，日期轴也
/// 容易压得看不清。这里改用 Flutter 原生绘制：左侧任务列固定，右侧时间轴独立
/// 横向滚动，任务条按分组着色，今天有一条标记线，点任务条可看完整日期。
///
/// 注意：本文件刻意使用 11.5 / 10.5 等非令牌字号——任务列与时间轴列宽按最窄
/// 手机屏压到极限，收敛到 AppTypography 的整数字号会把文字挤出列宽，故保留微调。
class GanttChartView extends StatefulWidget {
  final GanttPlan plan;

  const GanttChartView({super.key, required this.plan});

  @override
  State<GanttChartView> createState() => _GanttChartViewState();
}

enum _GanttScale { day, week, month }

sealed class _GanttRow {
  final double height;
  const _GanttRow(this.height);
}

class _GanttSectionRow extends _GanttRow {
  final GanttSection section;
  final int index;

  const _GanttSectionRow({required this.section, required this.index}) : super(_sectionRowHeight);
}

class _GanttTaskRow extends _GanttRow {
  final GanttTask task;
  final int sectionIndex;

  const _GanttTaskRow({required this.task, required this.sectionIndex}) : super(_taskRowHeight);
}

const double _headerHeight = 46;
const double _sectionRowHeight = 30;
const double _taskRowHeight = 46;

class _GanttChartViewState extends State<GanttChartView> {
  late _GanttScale _scale;
  final ScrollController _headerController = ScrollController();
  final ScrollController _bodyController = ScrollController();
  bool _syncingHeader = false;
  double _viewportWidth = 0;

  /// 当前选中的任务：左列任务行用实心竖条 + 极淡底标识，点开详情后仍保留。
  GanttTask? _selectedTask;

  @override
  void initState() {
    super.initState();
    _scale = _initialScale(widget.plan.daySpan);
    _bodyController.addListener(_syncHeader);
  }

  @override
  void didUpdateWidget(covariant GanttChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plan != widget.plan) {
      _scale = _initialScale(widget.plan.daySpan);
      // 计划换了，旧任务对象不再属于新图表，清掉选中态避免高亮错行
      _selectedTask = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_bodyController.hasClients) _bodyController.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _bodyController.removeListener(_syncHeader);
    _headerController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  static _GanttScale _initialScale(int daySpan) {
    if (daySpan <= 21) return _GanttScale.day;
    if (daySpan <= 120) return _GanttScale.week;
    return _GanttScale.month;
  }

  double _dayWidthFor(double viewportWidth, int daySpan) {
    final base = switch (_scale) {
      _GanttScale.day => 28.0,
      _GanttScale.week => 10.0,
      _GanttScale.month => 3.4,
    };
    final min = switch (_scale) {
      _GanttScale.day => 22.0,
      _GanttScale.week => 8.0,
      _GanttScale.month => 3.0,
    };
    // 右侧留 28px 给里程碑/最后一天；能塞下就轻微压缩，塞不下才横向滚动
    final fill = math.max(0.0, viewportWidth - 28) / math.max(daySpan, 1);
    if (fill >= base) return fill.clamp(base, 96.0).toDouble();
    if (fill >= min) return fill;
    return base;
  }

  void _syncHeader() {
    if (_syncingHeader || !_headerController.hasClients || !_bodyController.hasClients) return;
    final target = _bodyController.offset.clamp(0.0, _headerController.position.maxScrollExtent);
    if ((_headerController.offset - target).abs() < 0.5) return;
    _syncingHeader = true;
    _headerController.jumpTo(target);
    _syncingHeader = false;
  }

  void _setScale(_GanttScale scale) {
    if (_scale == scale) return;
    final oldMax = _bodyController.hasClients ? _bodyController.position.maxScrollExtent : 0.0;
    final ratio = oldMax > 0 ? (_bodyController.offset / oldMax).clamp(0.0, 1.0) : 0.0;
    setState(() => _scale = scale);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_bodyController.hasClients) return;
      final newMax = _bodyController.position.maxScrollExtent;
      _bodyController.jumpTo((ratio * newMax).clamp(0.0, newMax));
    });
  }

  void _scrollToToday(double dayWidth) {
    if (!_bodyController.hasClients) return;
    final today = DateTime.now();
    if (!widget.plan.containsDate(today)) return;
    final x = _dayOffset(today) * dayWidth + dayWidth / 2;
    final target = (x - _viewportWidth / 2).clamp(0.0, _bodyController.position.maxScrollExtent);
    _bodyController.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  List<_GanttRow> _buildRows() {
    final rows = <_GanttRow>[];
    for (var i = 0; i < widget.plan.sections.length; i++) {
      final section = widget.plan.sections[i];
      rows.add(_GanttSectionRow(section: section, index: i));
      for (final task in section.tasks) {
        rows.add(_GanttTaskRow(task: task, sectionIndex: i));
      }
    }
    return rows;
  }

  /// 任务起点相对图表起点的天数，保留小时/分钟的小数部分
  double _dayOffset(DateTime value) {
    final start = widget.plan.rangeStart;
    final base = DateTime.utc(start.year, start.month, start.day);
    final target = DateTime.utc(value.year, value.month, value.day);
    final whole = target.difference(base).inDays;
    final fraction = (value.hour * 60 + value.minute) / (24 * 60);
    return whole + fraction;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = widget.plan;
    if (plan.tasks.isEmpty) {
      return _buildEmptyState(theme);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width <= 0) return const SizedBox.shrink();
        final labelWidth = width >= 600 ? 160.0 : (width * 0.34).clamp(104.0, 148.0).toDouble();
        final viewportWidth = math.max(0.0, width - labelWidth);
        _viewportWidth = viewportWidth;
        final dayWidth = _dayWidthFor(viewportWidth, plan.daySpan);
        final contentWidth = math.max(viewportWidth, plan.daySpan * dayWidth + 28);
        final rows = _buildRows();
        final totalHeight = rows.fold<double>(0, (sum, row) => sum + row.height);
        final gridLines = _buildGridLines(dayWidth);
        final today = DateTime.now();
        final todayX = plan.containsDate(today) ? _dayOffset(today) * dayWidth : null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 14, 12, 0), child: _buildToolbar(theme, dayWidth)),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(width: labelWidth, height: _headerHeight, child: _buildLabelHeader(theme)),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _headerController,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: contentWidth,
                      height: _headerHeight,
                      child: _buildTimelineHeader(theme, dayWidth, gridLines, todayX),
                    ),
                  ),
                ),
              ],
            ),
            Divider(height: 1, thickness: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: labelWidth, child: _buildLabelColumn(theme, rows)),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _bodyController,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: contentWidth,
                          height: totalHeight,
                          child: _buildTimelineBody(theme, rows, dayWidth, gridLines, todayX),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── 顶部：标题 / 缩放 / 今天 ─────────────────────────────

  Widget _buildToolbar(ThemeData theme, double dayWidth) {
    final plan = widget.plan;
    final hasToday = plan.containsDate(DateTime.now());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                plan.title ?? '任务排期',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                '${plan.taskCount} 个任务 · ${plan.sections.length} 个阶段',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (hasToday) ...[_buildTodayButton(theme, dayWidth), const SizedBox(width: 4)],
        _buildScaleSelector(theme),
      ],
    );
  }

  Widget _buildTodayButton(ThemeData theme, double dayWidth) {
    return Tooltip(
      message: '回到今天',
      child: Material(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => _scrollToToday(dayWidth),
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(Icons.today_rounded, size: 17, color: theme.colorScheme.onPrimary),
          ),
        ),
      ),
    );
  }

  Widget _buildScaleSelector(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildScaleChip(theme, _GanttScale.day, '日'),
          _buildScaleChip(theme, _GanttScale.week, '周'),
          _buildScaleChip(theme, _GanttScale.month, '月'),
        ],
      ),
    );
  }

  Widget _buildScaleChip(ThemeData theme, _GanttScale scale, String label) {
    final selected = _scale == scale;
    return Material(
      color: selected ? theme.colorScheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: () => _setScale(scale),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  // ── 表头与网格 ─────────────────────────────────────────

  Widget _buildLabelHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: scheme.primary,
        // 表头是一整条实心色块，列分隔只用 onPrimary 低透明度发丝线
        border: Border(right: BorderSide(color: scheme.onPrimary.withValues(alpha: 0.28))),
      ),
      child: Row(
        children: [
          Text(
            '任务',
            style: theme.textTheme.labelMedium?.copyWith(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimary,
            ),
          ),
          const Spacer(),
          Text(
            '${widget.plan.taskCount}',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: scheme.onPrimary.withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineHeader(ThemeData theme, double dayWidth, List<_GridLine> gridLines, double? todayX) {
    final scheme = theme.colorScheme;
    final months = _buildMonthTicks(dayWidth);
    final axis = _buildAxisTicks(dayWidth);
    return ClipRect(
      child: ColoredBox(
        color: scheme.primary,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _GanttHeaderPainter(
                  gridLines: gridLines,
                  // 实心 primary 表头上的分隔：onPrimary 低透明度发丝线
                  gridColor: scheme.onPrimary,
                  todayX: todayX,
                  todayColor: scheme.error,
                ),
              ),
            ),
            for (final month in months)
              Positioned(
                left: month.x + 6,
                top: 4,
                child: Text(
                  month.label,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            for (final tick in axis)
              Positioned(
                left: tick.x + 2,
                top: 25,
                child: Text(
                  tick.label,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: scheme.onPrimary.withValues(alpha: 0.78),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            if (todayX != null)
              Positioned(
                left: todayX + 4,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    '今天',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: scheme.onError,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<_HeaderTick> _buildMonthTicks(double dayWidth) {
    final start = widget.plan.rangeStart;
    final end = widget.plan.rangeEnd;
    // rangeStart 是向前留出的一天，最早任务从它的下一天开始；以任务所在月作为首个月标签，
    // 避免「8月31日留白 + 9月1日任务」时 8 月/9 月两个标签挤在一起。
    final firstTaskStart = DateTime(start.year, start.month, start.day + 1);
    final firstMonth = DateTime(firstTaskStart.year, firstTaskStart.month, 1);
    final nextMonth = DateTime(firstTaskStart.year, firstTaskStart.month + 1, 1);
    final daysInFirstMonth = nextMonth.difference(firstTaskStart).inDays;
    final labelStart = daysInFirstMonth < 7 ? nextMonth : firstMonth;
    final ticks = <_HeaderTick>[_HeaderTick(0, _monthLabel(labelStart, first: true))];
    var cursor = DateTime(labelStart.year, labelStart.month + 1, 1);
    while (cursor.isBefore(end)) {
      final x = _dayOffset(cursor) * dayWidth;
      ticks.add(_HeaderTick(x, _monthLabel(cursor, first: false)));
      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }
    return ticks;
  }

  List<_HeaderTick> _buildAxisTicks(double dayWidth) {
    final start = widget.plan.rangeStart;
    final span = widget.plan.daySpan;
    final ticks = <_HeaderTick>[];
    switch (_scale) {
      case _GanttScale.day:
        for (var i = 0; i <= span; i++) {
          final date = DateTime(start.year, start.month, start.day + i);
          ticks.add(_HeaderTick(i * dayWidth + dayWidth / 2, '${date.day}'));
        }
      case _GanttScale.week:
        for (var i = 0; i < span; i++) {
          final date = DateTime(start.year, start.month, start.day + i);
          // 只标周一；起始日若紧邻周一，再标一次会和它挤在一起
          if (date.weekday == DateTime.monday) {
            ticks.add(_HeaderTick(i * dayWidth, '${date.month}/${date.day}'));
          }
        }
      case _GanttScale.month:
        // 月视图顶部已有月份标签，底部不再重复
        break;
    }
    return ticks;
  }

  String _monthLabel(DateTime date, {required bool first}) {
    if (first || date.month == 1) return '${date.year}年${date.month}月';
    return '${date.month}月';
  }

  List<_GridLine> _buildGridLines(double dayWidth) {
    final start = widget.plan.rangeStart;
    final span = widget.plan.daySpan;
    final lines = <_GridLine>[];
    for (var i = 0; i <= span; i++) {
      final date = DateTime(start.year, start.month, start.day + i);
      final major = i == 0 || date.day == 1;
      final visible = switch (_scale) {
        _GanttScale.day => true,
        _GanttScale.week => i == 0 || date.weekday == DateTime.monday,
        _GanttScale.month => i == 0 || date.day == 1,
      };
      if (visible) lines.add(_GridLine(i * dayWidth, major: major));
    }
    return lines;
  }

  // ── 左侧任务列 ─────────────────────────────────────────

  Widget _buildLabelColumn(ThemeData theme, List<_GanttRow> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          SizedBox(
            height: row.height,
            child: switch (row) {
              _GanttSectionRow() => _buildSectionLabel(theme, row),
              _GanttTaskRow() => _buildTaskLabel(theme, row),
            },
          ),
      ],
    );
  }

  Widget _buildSectionLabel(ThemeData theme, _GanttSectionRow row) {
    final scheme = theme.colorScheme;
    // 分组行保留既有 section 取色，但强调方式改为左缘实心窄条
    final color = _sectionColor(theme, row.index);
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
        border: Border(
          left: BorderSide(color: color, width: 3.5),
          right: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.section.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          Text(
            '${row.section.tasks.length}',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskLabel(ThemeData theme, _GanttTaskRow row) {
    final task = row.task;
    final scheme = theme.colorScheme;
    final color = _taskAccentColor(theme, task);
    final selected = _selectedTask == task;
    final end = _displayEndDate(task);
    final dateText = _isSameDay(task.start, end)
        ? _shortDate(task.start)
        : '${_shortDate(task.start)} → ${_shortDate(end)}';
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        // 选中态：极淡底 + 左缘实心竖条；未选中保留同宽透明占位，避免文字左右跳动
        color: selected ? scheme.primary.withValues(alpha: 0.06) : null,
        border: Border(
          left: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 3),
          right: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_statusIcon(task), size: 14, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11.5,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 时间轴主体 ─────────────────────────────────────────

  Widget _buildTimelineBody(
    ThemeData theme,
    List<_GanttRow> rows,
    double dayWidth,
    List<_GridLine> gridLines,
    double? todayX,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    final bars = <Widget>[];
    var top = 0.0;
    for (final row in rows) {
      if (row is _GanttTaskRow) {
        bars.add(_buildTaskBar(theme, row, dayWidth, top));
      }
      top += row.height;
    }
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _GanttBodyPainter(
              rows: rows,
              gridLines: gridLines,
              // 网格统一用 outlineVariant 的 1px 发丝线，透明度在 painter 内弱化
              gridColor: scheme.outlineVariant,
              sectionBandColor: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
              weekendColor: scheme.onSurface.withValues(alpha: isDark ? 0.028 : 0.018),
              todayX: todayX,
              todayColor: scheme.error,
              dayWidth: dayWidth,
              rangeStart: widget.plan.rangeStart,
              daySpan: widget.plan.daySpan,
              showWeekends: _scale == _GanttScale.day,
            ),
          ),
        ),
        ...bars,
      ],
    );
  }

  Widget _buildTaskBar(ThemeData theme, _GanttTaskRow row, double dayWidth, double rowTop) {
    final task = row.task;
    // 实心大色块：普通/进行中 = primary，关键 = error，完成 = 降饱和实心 + 对勾
    final fill = _barFill(theme, task);
    final ink = _barInk(theme, task);
    final startX = _dayOffset(task.start) * dayWidth;
    final endX = _dayOffset(task.end) * dayWidth;
    final width = math.max(6.0, endX - startX);

    final Widget bar;
    if (task.milestone) {
      bar = SizedBox(
        width: 14,
        height: 14,
        child: Center(
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ),
      );
    } else {
      bar = Container(
        width: width,
        height: 20,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
        child: width >= 24 ? Center(child: Icon(_statusIcon(task), size: 12, color: ink)) : null,
      );
    }

    return Positioned(
      left: math.max(0, startX - 4),
      top: rowTop,
      width: width + 8,
      height: row.height,
      child: Semantics(
        label: '${task.name}，${ganttTaskStatusLabel(task.status)}，${_fullDate(task.start)} 至 ${_displayEnd(task)}',
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _selectedTask = task);
            _showTaskDetails(task);
          },
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: task.milestone ? 0 : 4),
              child: bar,
            ),
          ),
        ),
      ),
    );
  }

  // ── 颜色 / 图标 / 日期格式 ──────────────────────────────

  Color _sectionColor(ThemeData theme, int index) {
    final scheme = theme.colorScheme;
    final anchors = <Color>[scheme.primary, scheme.tertiary, scheme.secondary];
    if (index < anchors.length) {
      final anchor = anchors[index];
      // 主题的 secondary 在浅色下偏中性，混一点 primary 让分组仍有色相
      return index == 2 ? Color.lerp(anchor, scheme.primary, 0.4)! : anchor;
    }
    final base = HSLColor.fromColor(index.isEven ? scheme.primary : scheme.tertiary);
    final hue = (base.hue + (index - 2) * 36) % 360;
    final saturation = base.saturation.clamp(0.35, 0.72).toDouble();
    final lightness = theme.brightness == Brightness.dark ? 0.64 : 0.46;
    return HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
  }

  /// 任务条/徽章的实心底色：单一 primary 锚点色，关键任务换 error。
  Color _barFill(ThemeData theme, GanttTask task) {
    final scheme = theme.colorScheme;
    if (task.status == GanttTaskStatus.crit) {
      return scheme.error;
    }
    if (task.status == GanttTaskStatus.done) {
      // 完成态降饱和：向容器色混合，仍是实心块，靠对勾与颜色双重区分
      return Color.lerp(scheme.primary, scheme.surfaceContainerHighest, 0.58)!;
    }
    return scheme.primary;
  }

  /// 实心色块上的前景色：优先用主题配对的 onXxx，降饱和色块交给 AppContrast。
  Color _barInk(ThemeData theme, GanttTask task) {
    final scheme = theme.colorScheme;
    if (task.status == GanttTaskStatus.crit) {
      return scheme.onError;
    }
    if (task.status == GanttTaskStatus.done) {
      return AppContrast.onColor(_barFill(theme, task));
    }
    return scheme.onPrimary;
  }

  /// 左列任务图标等「小面积前景」的用色，保证落在画布上可读。
  Color _taskAccentColor(ThemeData theme, GanttTask task) {
    return switch (task.status) {
      GanttTaskStatus.crit => theme.colorScheme.error,
      GanttTaskStatus.done => theme.colorScheme.onSurfaceVariant,
      _ => theme.accentInk,
    };
  }

  IconData _statusIcon(GanttTask task) {
    if (task.milestone) return Icons.diamond_rounded;
    return switch (task.status) {
      GanttTaskStatus.done => Icons.check_circle_rounded,
      GanttTaskStatus.active => Icons.play_circle_fill_rounded,
      GanttTaskStatus.crit => Icons.error_rounded,
      GanttTaskStatus.normal => Icons.circle_outlined,
    };
  }

  String _shortDate(DateTime date) => '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _fullDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  DateTime _previousDay(DateTime date) => DateTime(date.year, date.month, date.day - 1);

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// 展示用结束日：Mermaid 的结束日期包含当天，而内部统一存排他终点。
  ///
  /// 只有「整日任务」才把终点减一天；带小时的任务（如 6h）当天结束就显示当天。
  DateTime _displayEndDate(GanttTask task) {
    if (task.milestone) return task.start;
    final end = task.end;
    final wholeDayEnd = end.hour == 0 && end.minute == 0 && end.second == 0;
    return wholeDayEnd ? _previousDay(end) : end;
  }

  String _displayEnd(GanttTask task) => _fullDate(_displayEndDate(task));

  String _durationLabel(GanttTask task) {
    if (task.milestone) return '里程碑';
    final duration = task.duration;
    if (duration.inDays >= 1) return '${duration.inDays} 天';
    if (duration.inHours >= 1) return '${duration.inHours} 小时';
    return '${duration.inMinutes} 分钟';
  }

  // ── 任务详情 ───────────────────────────────────────────

  Future<void> _showTaskDetails(GanttTask task) {
    return showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final fill = _barFill(theme, task);
        final ink = _barInk(theme, task);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
                      child: Icon(_statusIcon(task), size: 22, color: ink),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            task.section.isEmpty ? '任务' : task.section,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildStatusChip(theme, task),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildDetailMetric(theme, '开始', _fullDate(task.start))),
                    const SizedBox(width: 12),
                    Expanded(child: _buildDetailMetric(theme, '结束', _displayEnd(task))),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildDetailMetric(theme, '工期', _durationLabel(task))),
                    const SizedBox(width: 12),
                    Expanded(child: _buildDetailMetric(theme, '状态', ganttTaskStatusLabel(task.status))),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _taskCopyText(task)));
                          if (sheetContext.mounted) Toast.info(sheetContext, '已复制任务信息');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('复制任务信息'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: () => Navigator.of(sheetContext).pop(), child: const Text('关闭')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusChip(ThemeData theme, GanttTask task) {
    final fill = _barFill(theme, task);
    final ink = _barInk(theme, task);
    final label = task.milestone ? '里程碑' : ganttTaskStatusLabel(task.status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w700, color: ink),
      ),
    );
  }

  /// 详情页的「小标签 + 大数值」两层排版，日期/工期用等宽数字方便对齐比较。
  Widget _buildDetailMetric(ThemeData theme, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  String _taskCopyText(GanttTask task) => [
    task.name,
    '分组：${task.section.isEmpty ? '任务' : task.section}',
    '开始：${_fullDate(task.start)}',
    '结束：${_displayEnd(task)}',
    '工期：${_durationLabel(task)}',
    '状态：${ganttTaskStatusLabel(task.status)}',
  ].join('\n');

  Widget _buildEmptyState(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              child: Icon(Icons.view_timeline_outlined, size: 26, color: scheme.onPrimary),
            ),
            const SizedBox(height: 14),
            Text('没有可显示的任务', style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '检查甘特图源码里是否包含任务行',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderTick {
  final double x;
  final String label;

  const _HeaderTick(this.x, this.label);
}

class _GridLine {
  final double x;
  final bool major;

  const _GridLine(this.x, {required this.major});
}

class _GanttHeaderPainter extends CustomPainter {
  final List<_GridLine> gridLines;
  final Color gridColor;
  final double? todayX;
  final Color todayColor;

  const _GanttHeaderPainter({
    required this.gridLines,
    required this.gridColor,
    required this.todayX,
    required this.todayColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 实心 primary 表头上的细线：用 onPrimary 低透明度，仍是 1px 发丝线
    final paint = Paint()..strokeWidth = 1;
    for (final line in gridLines) {
      paint.color = gridColor.withValues(alpha: line.major ? 0.34 : 0.16);
      canvas.drawLine(Offset(line.x, 0), Offset(line.x, size.height), paint);
    }
    final today = todayX;
    if (today != null) {
      canvas.drawLine(
        Offset(today, 0),
        Offset(today, size.height),
        Paint()
          ..color = todayColor
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GanttHeaderPainter oldDelegate) =>
      oldDelegate.gridLines != gridLines ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.todayX != todayX ||
      oldDelegate.todayColor != todayColor;
}

class _GanttBodyPainter extends CustomPainter {
  final List<_GanttRow> rows;
  final List<_GridLine> gridLines;
  final Color gridColor;
  final Color sectionBandColor;
  final Color weekendColor;
  final double? todayX;
  final Color todayColor;
  final double dayWidth;
  final DateTime rangeStart;
  final int daySpan;
  final bool showWeekends;

  const _GanttBodyPainter({
    required this.rows,
    required this.gridLines,
    required this.gridColor,
    required this.sectionBandColor,
    required this.weekendColor,
    required this.todayX,
    required this.todayColor,
    required this.dayWidth,
    required this.rangeStart,
    required this.daySpan,
    required this.showWeekends,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (showWeekends) {
      final weekendPaint = Paint()..color = weekendColor;
      for (var i = 0; i < daySpan; i++) {
        final date = DateTime(rangeStart.year, rangeStart.month, rangeStart.day + i);
        if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
          canvas.drawRect(Rect.fromLTWH(i * dayWidth, 0, dayWidth, size.height), weekendPaint);
        }
      }
    }

    var top = 0.0;
    for (final row in rows) {
      if (row is _GanttSectionRow) {
        canvas.drawRect(Rect.fromLTWH(0, top, size.width, row.height), Paint()..color = sectionBandColor);
      }
      top += row.height;
    }

    final horizontal = Paint()
      ..color = gridColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    top = 0;
    for (final row in rows) {
      top += row.height;
      canvas.drawLine(Offset(0, top), Offset(size.width, top), horizontal);
    }

    final vertical = Paint()..strokeWidth = 1;
    for (final line in gridLines) {
      vertical.color = gridColor.withValues(alpha: line.major ? 0.8 : 0.45);
      canvas.drawLine(Offset(line.x, 0), Offset(line.x, size.height), vertical);
    }

    final today = todayX;
    if (today != null) {
      canvas.drawLine(
        Offset(today, 0),
        Offset(today, size.height),
        Paint()
          ..color = todayColor
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GanttBodyPainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.gridLines != gridLines ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.sectionBandColor != sectionBandColor ||
      oldDelegate.weekendColor != weekendColor ||
      oldDelegate.todayX != todayX ||
      oldDelegate.todayColor != todayColor ||
      oldDelegate.dayWidth != dayWidth ||
      oldDelegate.rangeStart != rangeStart ||
      oldDelegate.daySpan != daySpan ||
      oldDelegate.showWeekends != showWeekends;
}
