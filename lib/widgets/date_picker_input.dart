import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DatePickerInput extends StatelessWidget {
  final DateTime? selectedDate;
  final ValueChanged<DateTime?> onDateSelected;
  final String label;
  final DateTime firstDate;
  final DateTime lastDate;
  final bool showClearButton;

  DatePickerInput({
    super.key,
    this.selectedDate,
    required this.onDateSelected,
    required this.label,
    DateTime? firstDate,
    DateTime? lastDate,
    this.showClearButton = true,
  })  : firstDate = firstDate ?? DateTime(2000),
        lastDate = lastDate ?? DateTime(2100);

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate ?? DateTime.now(),
      firstDate: firstDate,
      lastDate: lastDate,
      locale: const Locale('zh', 'CN'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).colorScheme.primary,
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      onDateSelected(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDate = selectedDate != null;
    final displayText = hasDate ? DateFormat('yyyy-MM-dd').format(selectedDate!) : '';

    return GestureDetector(
      onTap: () => _pickDate(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showClearButton && hasDate)
                IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => onDateSelected(null),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              const Icon(Icons.calendar_today, size: 18),
              const SizedBox(width: 12),
            ],
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        isEmpty: !hasDate,
        child: Text(
          hasDate ? displayText : '',
          style: hasDate
              ? theme.textTheme.bodyLarge
              : theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
      ),
    );
  }
}
