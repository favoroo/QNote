import 'package:flutter/material.dart';

enum TimeRangeType { week, month, year }

class TimeRangeSelector extends StatelessWidget {
  final TimeRangeType selectedRange;
  final ValueChanged<TimeRangeType> onRangeChanged;

  const TimeRangeSelector({
    super.key,
    required this.selectedRange,
    required this.onRangeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: TimeRangeType.values.map((range) {
          final isSelected = range == selectedRange;
          return GestureDetector(
            onTap: () => onRangeChanged(range),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? colorScheme.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        )
                      ]
                    : null,
              ),
              child: Text(
                _label(range),
                style: TextStyle(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _label(TimeRangeType range) {
    switch (range) {
      case TimeRangeType.week:
        return '周';
      case TimeRangeType.month:
        return '月';
      case TimeRangeType.year:
        return '年';
    }
  }
}
