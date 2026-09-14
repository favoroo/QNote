import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 自定义日期范围选择器对话框
class CustomDateRangePickerDialog extends StatefulWidget {
  final DateTimeRange? initialDateRange;
  final DateTime firstDate;
  final DateTime lastDate;

  const CustomDateRangePickerDialog({
    super.key,
    this.initialDateRange,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<CustomDateRangePickerDialog> createState() =>
      _CustomDateRangePickerDialogState();
}

class _CustomDateRangePickerDialogState
    extends State<CustomDateRangePickerDialog> {
  late DateTime _focusedMonth;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month);

    if (widget.initialDateRange != null) {
      _startDate = widget.initialDateRange!.start;
      _endDate = widget.initialDateRange!.end;
    }
  }

  void _prevMonth() {
    setState(() {
      int prevYear = _focusedMonth.year;
      int prevMonth = _focusedMonth.month - 1;
      if (prevMonth == 0) {
        prevMonth = 12;
        prevYear -= 1;
      }
      final newMonth = DateTime(prevYear, prevMonth);
      if (newMonth.isAfter(widget.firstDate) ||
          newMonth.isAtSameMomentAs(widget.firstDate)) {
        _focusedMonth = newMonth;
      }
    });
  }

  void _nextMonth() {
    setState(() {
      int nextYear = _focusedMonth.year;
      int nextMonth = _focusedMonth.month + 1;
      if (nextMonth == 13) {
        nextMonth = 1;
        nextYear += 1;
      }
      final newMonth = DateTime(nextYear, nextMonth);
      if (newMonth.isBefore(widget.lastDate) ||
          newMonth.isAtSameMomentAs(widget.lastDate)) {
        _focusedMonth = newMonth;
      }
    });
  }

  /// 快捷选择本周（周一到今天）
  void _selectThisWeek() {
    final now = DateTime.now();
    // weekday: 1=周一 ... 7=周日
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final startDate = DateTime(monday.year, monday.month, monday.day);
    final endDate = DateTime(now.year, now.month, now.day);
    setState(() {
      _startDate = startDate;
      _endDate = endDate;
      // 始终显示当前月份的日历，高亮范围可以跨月
      _focusedMonth = DateTime(now.year, now.month);
    });
  }

  /// 快捷选择今天
  void _selectToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _startDate = today;
      _endDate = today;
      _focusedMonth = DateTime(now.year, now.month);
    });
  }

  /// 快捷选择本月（1号到今天）
  void _selectThisMonth() {
    final now = DateTime.now();
    final startDate = DateTime(now.year, now.month, 1);
    final endDate = DateTime(now.year, now.month, now.day);
    setState(() {
      _startDate = startDate;
      _endDate = endDate;
      _focusedMonth = DateTime(now.year, now.month);
    });
  }

  void _onDateTapped(DateTime date) {
    setState(() {
      if (_startDate == null || (_startDate != null && _endDate != null)) {
        // 重新开始选择
        _startDate = date;
        _endDate = null;
      } else if (_dateOnly(date).isBefore(_dateOnly(_startDate!))) {
        // 如果点击的日期早于开始日期，更新开始日期
        _startDate = date;
      } else {
        // 设置结束日期
        _endDate = date;
      }
    });
  }

  DateTime _dateOnly(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  bool _isInRange(DateTime date) {
    if (_startDate == null || _endDate == null) return false;
    final d = _dateOnly(date);
    final start = _dateOnly(_startDate!);
    final end = _dateOnly(_endDate!);
    return d.isAfter(start) && d.isBefore(end);
  }

  bool _isStartDate(DateTime date) {
    if (_startDate == null) return false;
    return _dateOnly(date) == _dateOnly(_startDate!);
  }

  bool _isEndDate(DateTime date) {
    if (_endDate == null) return false;
    return _dateOnly(date) == _dateOnly(_endDate!);
  }

  List<DateTime> _generateCalendarDays() {
    final firstDayOfMonth = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final int offset = firstDayOfMonth.weekday % 7; // Sunday start (0) to Saturday (6)
    final gridStartDate = firstDayOfMonth.subtract(Duration(days: offset));

    return List.generate(42, (index) => gridStartDate.add(Duration(days: index)));
  }

  String _formatDateRange() {
    if (_startDate == null) return '请选择日期范围';
    final startStr = DateFormat('yyyy-MM-dd').format(_startDate!);
    if (_endDate == null) return '$startStr 至 ...';
    final endStr = DateFormat('yyyy-MM-dd').format(_endDate!);
    return '$startStr 至 $endStr';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final days = _generateCalendarDays();
    final monthName = DateFormat('yyyy年 M月', 'zh_CN').format(_focusedMonth);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      elevation: 0,
      backgroundColor: theme.cardColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: Selected Date Range Display
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 8, bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '选择日期范围',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatDateRange(),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // Quick Select Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: const Text('今天'),
                    onPressed: _selectToday,
                    avatar: Icon(Icons.today, size: 16, color: colorScheme.primary),
                  ),
                  ActionChip(
                    label: const Text('本周'),
                    onPressed: _selectThisWeek,
                    avatar: Icon(Icons.date_range, size: 16, color: colorScheme.primary),
                  ),
                  ActionChip(
                    label: const Text('本月'),
                    onPressed: _selectThisMonth,
                    avatar: Icon(Icons.calendar_month, size: 16, color: colorScheme.primary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Month Navigation Bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 24),
                  onPressed: _prevMonth,
                ),
                Text(
                  monthName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 24),
                  onPressed: _nextMonth,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Weekday Headings
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: const [
                _WeekdayLabel(label: '日'),
                _WeekdayLabel(label: '一'),
                _WeekdayLabel(label: '二'),
                _WeekdayLabel(label: '三'),
                _WeekdayLabel(label: '四'),
                _WeekdayLabel(label: '五'),
                _WeekdayLabel(label: '六'),
              ],
            ),
            const SizedBox(height: 8),

            // Calendar Days Grid (使用 Column+Row 确保 setState 后完整重建)
            ...List.generate(6, (weekIndex) {
              final weekDays = days.sublist(weekIndex * 7, weekIndex * 7 + 7);
              // 跳过全为空行的周（避免多余空白）
              final hasCurrentMonthDay = weekDays.any((d) => d.month == _focusedMonth.month);
              if (!hasCurrentMonthDay && weekIndex > 4) return const SizedBox.shrink();
              return Row(
                children: weekDays.map((date) {
                  final isCurrentMonth = date.month == _focusedMonth.month;
                  final isStart = _isStartDate(date);
                  final isEnd = _isEndDate(date);
                  final inRange = _isInRange(date);

                  return Expanded(
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: GestureDetector(
                        onTap: isCurrentMonth ? () => _onDateTapped(date) : null,
                        child: Container(
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: (isStart || isEnd)
                                ? colorScheme.primary
                                : (inRange
                                    ? colorScheme.primary.withValues(alpha: 0.1)
                                    : null),
                            shape: (isStart || isEnd)
                                ? BoxShape.circle
                                : BoxShape.rectangle,
                            borderRadius: (isStart || isEnd) ? null : BorderRadius.circular(4),
                          ),
                          child: Center(
                            child: Text(
                              date.day.toString(),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: (isStart || isEnd) ? FontWeight.bold : FontWeight.normal,
                                color: (isStart || isEnd)
                                    ? Colors.white
                                    : isCurrentMonth
                                        ? colorScheme.onSurface
                                        : colorScheme.onSurface.withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            }),
            const SizedBox(height: 16),

            // Dialog Footer Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    '取消',
                    style: TextStyle(color: colorScheme.primary),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  onPressed: _startDate == null
                      ? null
                      : () {
                          final range = DateTimeRange(
                            start: _startDate!,
                            end: _endDate ?? _startDate!,
                          );
                          Navigator.pop(context, range);
                        },
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekdayLabel extends StatelessWidget {
  final String label;

  const _WeekdayLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 36,
      child: Center(
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
