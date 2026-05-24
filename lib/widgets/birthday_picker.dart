import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class BirthdayPickerDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  const BirthdayPickerDialog({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<BirthdayPickerDialog> createState() => _BirthdayPickerDialogState();
}

class _BirthdayPickerDialogState extends State<BirthdayPickerDialog> {
  int? _selectedYear;
  int? _selectedMonth;
  int? _selectedDay;

  // 0: Year, 1: Month, 2: Day
  int _step = 0;

  late ScrollController _yearScrollController;

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialDate.year;
    _selectedMonth = widget.initialDate.month;
    _selectedDay = widget.initialDate.day;

    final initialYearIndex = widget.lastDate.year - _selectedYear!;
    _yearScrollController = ScrollController(
      initialScrollOffset: initialYearIndex * 60.0,
    );
  }

  @override
  void dispose() {
    _yearScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String title = '选择出生年份';
    if (_step == 1) title = '选择出生月份';
    if (_step == 2) title = '选择出生日期';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            _buildCurrentSelection(theme),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            SizedBox(height: 280, child: _buildPickerContent(theme)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_step > 0)
                  TextButton(
                    onPressed: () => setState(() => _step--),
                    child: const Text('上一步'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    '取消',
                    style: TextStyle(color: theme.disabledColor),
                  ),
                ),
                if (_step == 2)
                  FilledButton(
                    onPressed: () {
                      final date = DateTime(
                        _selectedYear!,
                        _selectedMonth!,
                        _selectedDay!,
                      );
                      Navigator.pop(context, date);
                    },
                    child: const Text('完成'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentSelection(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildSelectionChip(
          theme,
          '${_selectedYear ?? ""}年',
          _step == 0,
          onTap: () => setState(() => _step = 0),
        ),
        const SizedBox(width: 8),
        _buildSelectionChip(
          theme,
          _selectedMonth != null ? '$_selectedMonth月' : "月",
          _step == 1,
          enabled: _selectedYear != null,
          onTap: () => setState(() => _step = 1),
        ),
        const SizedBox(width: 8),
        _buildSelectionChip(
          theme,
          _selectedDay != null ? '$_selectedDay日' : "日",
          _step == 2,
          enabled: _selectedMonth != null,
          onTap: () => setState(() => _step = 2),
        ),
      ],
    );
  }

  Widget _buildSelectionChip(
    ThemeData theme,
    String label,
    bool isSelected, {
    bool enabled = true,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: enabled ? 0.3 : 0.1,
                ),
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: theme.colorScheme.primary)
              : null,
        ),
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: enabled ? 1.0 : 0.3,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildPickerContent(ThemeData theme) {
    if (_step == 0) return _buildYearPicker(theme);
    if (_step == 1) return _buildMonthPicker(theme);
    return _buildDayPicker(theme);
  }

  Widget _buildYearPicker(ThemeData theme) {
    final years = List.generate(
      widget.lastDate.year - widget.firstDate.year + 1,
      (index) => widget.lastDate.year - index,
    );

    return Scrollbar(
      controller: _yearScrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _yearScrollController,
        itemCount: years.length,
        itemBuilder: (context, index) {
          final year = years[index];
          final isSelected = year == _selectedYear;
          return ListTile(
            title: Text(
              '$year年',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? theme.colorScheme.primary : null,
              ),
            ),
            selected: isSelected,
            onTap: () {
              setState(() {
                _selectedYear = year;
                _step = 1;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildMonthPicker(ThemeData theme) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 1.2,
      ),
      itemCount: 12,
      itemBuilder: (context, index) {
        final month = index + 1;
        final isSelected = month == _selectedMonth;
        return InkWell(
          onTap: () {
            setState(() {
              _selectedMonth = month;
              _step = 2;
              // Reset day if it's invalid for new month
              if (_selectedDay != null) {
                final lastDay = _daysInMonth(_selectedYear!, month);
                if (_selectedDay! > lastDay) {
                  _selectedDay = lastDay;
                }
              }
            });
          },
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? theme.colorScheme.primary : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$month月',
                style: TextStyle(
                  color: isSelected ? theme.colorScheme.onPrimary : null,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDayPicker(ThemeData theme) {
    final daysCount = _daysInMonth(_selectedYear!, _selectedMonth!);
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 1,
      ),
      itemCount: daysCount,
      itemBuilder: (context, index) {
        final day = index + 1;
        final isSelected = day == _selectedDay;
        return InkWell(
          onTap: () {
            setState(() {
              _selectedDay = day;
            });
          },
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isSelected ? theme.colorScheme.primary : null,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 13,
                    color: isSelected ? theme.colorScheme.onPrimary : null,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  int _daysInMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }
}

Future<DateTime?> showBirthdayPicker({
  required BuildContext context,
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  return showDialog<DateTime>(
    context: context,
    builder: (context) => BirthdayPickerDialog(
      initialDate: initialDate,
      firstDate: firstDate ?? DateTime(1900),
      lastDate: lastDate ?? DateTime.now(),
    ),
  );
}
