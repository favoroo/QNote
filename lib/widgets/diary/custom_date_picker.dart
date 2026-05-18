import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';

class CustomDatePickerDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final List<DateColorMark> colorMarks;

  const CustomDatePickerDialog({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.colorMarks,
  });

  @override
  State<CustomDatePickerDialog> createState() => _CustomDatePickerDialogState();
}

class _CustomDatePickerDialogState extends State<CustomDatePickerDialog> {
  late DateTime _focusedMonth;
  late DateTime _selectedDate;
  late Map<String, Color> _colorMarkMap;

  @override
  void initState() {
    super.initState();
    _focusedMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
    _selectedDate = DateTime(widget.initialDate.year, widget.initialDate.month, widget.initialDate.day);
    _buildColorMarkMap();
  }

  void _buildColorMarkMap() {
    _colorMarkMap = {};
    for (final mark in widget.colorMarks) {
      final key = _formatDateKey(mark.date);
      final color = _parseHexColor(mark.color);
      if (color != Colors.transparent) {
        _colorMarkMap[key] = color;
      }
    }
  }

  String _formatDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Color _parseHexColor(String hex) {
    try {
      final cleanHex = hex.replaceAll('#', '').trim();
      if (cleanHex.length == 6) {
        return Color(int.parse('FF$cleanHex', radix: 16));
      } else if (cleanHex.length == 8) {
        return Color(int.parse(cleanHex, radix: 16));
      }
    } catch (_) {}
    return Colors.transparent;
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
      if (newMonth.isAfter(widget.firstDate) || newMonth.isAtSameMomentAs(widget.firstDate)) {
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
      if (newMonth.isBefore(widget.lastDate) || newMonth.isAtSameMomentAs(widget.lastDate)) {
        _focusedMonth = newMonth;
      }
    });
  }

  List<DateTime> _generateCalendarDays() {
    final firstDayOfMonth = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final int offset = firstDayOfMonth.weekday % 7; // Sunday start (0) to Saturday (6)
    final gridStartDate = firstDayOfMonth.subtract(Duration(days: offset));

    return List.generate(42, (index) => gridStartDate.add(Duration(days: index)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final days = _generateCalendarDays();
    final monthName = DateFormat('yyyy年 M月', 'zh_CN').format(_focusedMonth);
    final selectedDateStr = DateFormat('yyyy年 M月 d日 EEEE', 'zh_CN').format(_selectedDate);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      elevation: 0,
      backgroundColor: theme.cardColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 328,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: Selected Date Display
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 8, bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '选择日期',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    selectedDateStr,
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

            // Calendar Days Grid
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 1.0,
              ),
              itemCount: 42,
              itemBuilder: (context, index) {
                final date = days[index];
                final isCurrentMonth = date.month == _focusedMonth.month;
                final isSelected = date.year == _selectedDate.year &&
                    date.month == _selectedDate.month &&
                    date.day == _selectedDate.day;

                final dateKey = _formatDateKey(date);
                final markColor = _colorMarkMap[dateKey];

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedDate = date;
                      if (date.month != _focusedMonth.month) {
                        _focusedMonth = DateTime(date.year, date.month);
                      }
                    });
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Circular Background for Selected Day
                      if (isSelected)
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      // Day Text
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          date.day.toString(),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected
                                ? Colors.white
                                : isCurrentMonth
                                    ? colorScheme.onSurface
                                    : colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                      // Color Dot Marker
                      if (markColor != null)
                        Positioned(
                          bottom: 4,
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.white : markColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
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
                  onPressed: () => Navigator.pop(context, _selectedDate),
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
