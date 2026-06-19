import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';

enum TimePickerMode { date, time, dateTime }

Future<DateTime?> showTimePickerDialog({
  required BuildContext context,
  DateTime? initialTime,
  TimePickerMode mode = TimePickerMode.dateTime,
  String title = '设定时间',
}) async {
  final now = initialTime ?? DateTime.now();

  if (mode == TimePickerMode.dateTime) {
    return showDialog<DateTime>(
      context: context,
      builder: (context) => TimeDateDialog(
        initialDate: now,
        title: title,
      ),
    );
  }

  switch (mode) {
    case TimePickerMode.date:
      return showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );

    case TimePickerMode.time:
      final result = await showTimeScrollPicker(
        context: context,
        initialHour: now.hour,
        initialMinute: now.minute,
      );
      if (result == null) return null;
      return DateTime(
        now.year,
        now.month,
        now.day,
        result.hour,
        result.minute,
      );

    default:
      return null;
  }
}

class TimeDateDialog extends StatefulWidget {
  final DateTime initialDate;
  final String title;

  const TimeDateDialog({
    super.key,
    required this.initialDate,
    required this.title,
  });

  @override
  State<TimeDateDialog> createState() => _TimeDateDialogState();
}

class _TimeDateDialogState extends State<TimeDateDialog> {
  late DateTime _selectedDate;
  late int _selectedHour;
  late int _selectedMinute;

  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;

  bool _isKeyboardMode = false;
  late TextEditingController _hourInputController;
  late TextEditingController _minuteInputController;
  late FocusNode _hourFocusNode;
  late FocusNode _minuteFocusNode;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime(widget.initialDate.year, widget.initialDate.month, widget.initialDate.day);
    _selectedHour = widget.initialDate.hour;
    _selectedMinute = widget.initialDate.minute;

    _hourController = FixedExtentScrollController(initialItem: _selectedHour);
    _minuteController = FixedExtentScrollController(initialItem: _selectedMinute);

    _hourInputController = TextEditingController();
    _minuteInputController = TextEditingController();
    _hourFocusNode = FocusNode();
    _minuteFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _hourInputController.dispose();
    _minuteInputController.dispose();
    _hourFocusNode.dispose();
    _minuteFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 280,
              width: double.infinity,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Theme(
                data: theme.copyWith(
                  splashFactory: NoSplash.splashFactory,
                ),
                child: CalendarDatePicker(
                  initialDate: _selectedDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  onDateChanged: (date) {
                    setState(() {
                      _selectedDate = date;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '时间',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _isKeyboardMode = !_isKeyboardMode;
                      if (_isKeyboardMode) {
                        _hourInputController.text = _selectedHour.toString().padLeft(2, '0');
                        _minuteInputController.text = _selectedMinute.toString().padLeft(2, '0');
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _hourFocusNode.requestFocus();
                        });
                      } else {
                        _hourController.dispose();
                        _minuteController.dispose();
                        _hourController = FixedExtentScrollController(initialItem: _selectedHour);
                        _minuteController = FixedExtentScrollController(initialItem: _selectedMinute);
                      }
                    });
                  },
                  icon: Icon(_isKeyboardMode ? Icons.view_day_outlined : Icons.keyboard_outlined, size: 14),
                  label: Text(
                    _isKeyboardMode ? '滑动选择' : '键盘输入',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              height: 110,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: _isKeyboardMode
                  ? _buildKeyboardInput(theme)
                  : _buildScrollPickers(theme),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: () {
                  final result = DateTime(
                    _selectedDate.year,
                    _selectedDate.month,
                    _selectedDate.day,
                    _selectedHour,
                    _selectedMinute,
                  );
                  Navigator.pop(context, result);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 0),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '完成设定',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyboardInput(ThemeData theme) {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 70,
            height: 48,
            child: TextField(
              controller: _hourInputController,
              focusNode: _hourFocusNode,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 2,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
                ),
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (val) {
                final h = int.tryParse(val);
                if (h != null && h >= 0 && h < 24) {
                  setState(() {
                    _selectedHour = h;
                  });
                  if (val.length == 2) {
                    _minuteFocusNode.requestFocus();
                  }
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              ':',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
          SizedBox(
            width: 70,
            height: 48,
            child: TextField(
              controller: _minuteInputController,
              focusNode: _minuteFocusNode,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 2,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
                ),
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (val) {
                final m = int.tryParse(val);
                if (m != null && m >= 0 && m < 60) {
                  setState(() {
                    _selectedMinute = m;
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrollPickers(ThemeData theme) {
    return Stack(
      alignment: Alignment.center,
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              _isKeyboardMode = true;
              _hourInputController.text = _selectedHour.toString().padLeft(2, '0');
              _minuteInputController.text = _selectedMinute.toString().padLeft(2, '0');
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _hourFocusNode.requestFocus();
            });
          },
          child: Container(
            height: 36,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 70,
              height: 110,
              child: CupertinoPicker(
                scrollController: _hourController,
                itemExtent: 36,
                looping: true,
                selectionOverlay: const SizedBox.shrink(),
                onSelectedItemChanged: (index) {
                  setState(() => _selectedHour = index);
                },
                children: List.generate(24, (index) {
                  final isSelected = _selectedHour == index;
                  return Center(
                    child: Text(
                      index.toString().padLeft(2, '0'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        height: 1.0,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  );
                }),
              ),
            ),
            Text(
              ':',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            SizedBox(
              width: 70,
              height: 110,
              child: CupertinoPicker(
                scrollController: _minuteController,
                itemExtent: 36,
                looping: true,
                selectionOverlay: const SizedBox.shrink(),
                onSelectedItemChanged: (index) {
                  setState(() => _selectedMinute = index);
                },
                children: List.generate(60, (index) {
                  final isSelected = _selectedMinute == index;
                  return Center(
                    child: Text(
                      index.toString().padLeft(2, '0'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        height: 1.0,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class DashedRectPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double borderRadius;
  final double dashWidth;
  final double dashSpace;

  DashedRectPainter({
    required this.color,
    this.strokeWidth = 1.0,
    this.borderRadius = 0.0,
    this.dashWidth = 5.0,
    this.dashSpace = 3.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2, size.width - strokeWidth, size.height - strokeWidth),
        Radius.circular(borderRadius),
      ));

    final dashedPath = Path();
    for (final metric in path.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        dashedPath.addPath(
          metric.extractPath(distance, distance + dashWidth),
          Offset.zero,
        );
        distance += dashWidth + dashSpace;
      }
    }

    canvas.drawPath(dashedPath, paint);
  }

  @override
  bool shouldRepaint(covariant DashedRectPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.borderRadius != borderRadius;
  }
}
