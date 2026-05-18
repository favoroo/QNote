import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TimeRange {
  final DateTime startDate;
  final DateTime? endDate;

  const TimeRange({
    required this.startDate,
    this.endDate,
  });
}

Future<TimeRange?> showDateRangePickerDialog(BuildContext context) {
  return showDialog<TimeRange>(
    context: context,
    builder: (context) => const _DateRangePickerDialog(),
  );
}

class _DateRangePickerDialog extends StatefulWidget {
  const _DateRangePickerDialog();

  @override
  State<_DateRangePickerDialog> createState() => _DateRangePickerDialogState();
}

class _DateRangePickerDialogState extends State<_DateRangePickerDialog> {
  late DateTime _currentMonth;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime(DateTime.now().year, DateTime.now().month);
  }

  void _previousMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    });
  }

  void _selectDate(DateTime date) {
    setState(() {
      if (_startDate == null || (_startDate != null && _endDate != null)) {
        _startDate = date;
        _endDate = null;
      } else {
        if (date.isBefore(_startDate!)) {
          _endDate = _startDate;
          _startDate = date;
        } else {
          _endDate = date;
        }
      }
    });
  }

  void _applyQuickSelection(String type) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      switch (type) {
        case 'today':
          _startDate = today;
          _endDate = null;
          break;
        case 'week':
          final weekday = now.weekday;
          _startDate = today.subtract(Duration(days: weekday - 1));
          _endDate = today.add(Duration(days: 7 - weekday));
          break;
        case 'month':
          _startDate = DateTime(now.year, now.month, 1);
          _endDate = DateTime(now.year, now.month + 1, 0);
          break;
      }
    });
  }

  bool _isInRange(DateTime date) {
    if (_startDate == null) return false;
    if (_endDate == null) return date == _startDate;
    return (date.isAfter(_startDate!) || date == _startDate) &&
        (date.isBefore(_endDate!) || date == _endDate);
  }

  bool _isStartOrEnd(DateTime date) {
    return date == _startDate || date == _endDate;
  }

  List<Widget> _buildCalendarGrid() {
    final firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    final startWeekday = firstDayOfMonth.weekday % 7;
    final daysInMonth = lastDayOfMonth.day;

    final List<Widget> cells = [];

    for (int i = 0; i < startWeekday; i++) {
      cells.add(const SizedBox());
    }

    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_currentMonth.year, _currentMonth.month, day);
      final isSelected = _isStartOrEnd(date);
      final isInRange = _isInRange(date);
      final isToday = date == DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

      cells.add(
        GestureDetector(
          onTap: () => _selectDate(date),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : isInRange
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                      : null,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$day',
                style: TextStyle(
                  color: isSelected
                      ? Theme.of(context).colorScheme.onPrimary
                      : isToday
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface,
                  fontWeight: isToday || isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return cells;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monthLabel = DateFormat.yMMMM().format(_currentMonth);

    return AlertDialog(
      title: const Text('选择日期范围'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: _previousMonth,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  monthLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  onPressed: _nextMonth,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: ['日', '一', '二', '三', '四', '五', '六']
                  .map((d) => Expanded(
                        child: Center(
                          child: Text(
                            d,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              childAspectRatio: 1,
              children: _buildCalendarGrid(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _applyQuickSelection('today'),
                    child: const Text('今天'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _applyQuickSelection('week'),
                    child: const Text('本周'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _applyQuickSelection('month'),
                    child: const Text('本月'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildDateChip(
                    '开始',
                    _startDate,
                    theme,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildDateChip(
                    '结束',
                    _endDate,
                    theme,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _startDate != null
              ? () => Navigator.pop(
                    context,
                    TimeRange(startDate: _startDate!, endDate: _endDate),
                  )
              : null,
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildDateChip(String label, DateTime? date, ThemeData theme) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(
        date != null ? DateFormat.yMd().format(date) : '未选择',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: date != null
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
