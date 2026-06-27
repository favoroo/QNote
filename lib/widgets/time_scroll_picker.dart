import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

class TimeScrollPicker extends StatefulWidget {
  final int initialHour;
  final int initialMinute;
  final ValueChanged<TimeOfDay> onTimeSelected;

  TimeScrollPicker({
    super.key,
    int? initialHour,
    int? initialMinute,
    required this.onTimeSelected,
  })  : initialHour = initialHour ?? TimeOfDay.now().hour,
        initialMinute = initialMinute ?? TimeOfDay.now().minute;

  @override
  State<TimeScrollPicker> createState() => _TimeScrollPickerState();
}

class _TimeScrollPickerState extends State<TimeScrollPicker> {
  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;
  late int _selectedHour;
  late int _selectedMinute;

  bool _isKeyboardMode = false;
  late TextEditingController _hourInputController;
  late TextEditingController _minuteInputController;
  late FocusNode _hourFocusNode;
  late FocusNode _minuteFocusNode;

  static const double _itemExtent = 48.0;
  static const int _visibleItemCount = 5;

  @override
  void initState() {
    super.initState();
    _selectedHour = widget.initialHour;
    _selectedMinute = widget.initialMinute;
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
    final height = _itemExtent * _visibleItemCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _isKeyboardMode
            ? _buildKeyboardInput(theme, height)
            : _buildScrollPickers(theme, height),
        const SizedBox(height: 8),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  Widget _buildScrollPickers(ThemeData theme, double height) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                CupertinoPicker(
                  scrollController: _hourController,
                  itemExtent: _itemExtent,
                  looping: true,
                  selectionOverlay: const SizedBox.shrink(),
                  onSelectedItemChanged: (index) {
                    setState(() => _selectedHour = index);
                    _notifyChanged();
                  },
                  children: List.generate(24, (index) {
                    final isSelected = index == _selectedHour;
                    return Center(
                      child: Text(
                        index.toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          height: 1.0,
                          leadingDistribution: TextLeadingDistribution.even,
                        ),
                      ),
                    );
                  }),
                ),
                _buildCenterIndicator(theme, height),
              ],
            ),
          ),
          SizedBox(
            width: 32,
            child: Center(
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                  height: 1.0,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                CupertinoPicker(
                  scrollController: _minuteController,
                  itemExtent: _itemExtent,
                  looping: true,
                  selectionOverlay: const SizedBox.shrink(),
                  onSelectedItemChanged: (index) {
                    setState(() => _selectedMinute = index);
                    _notifyChanged();
                  },
                  children: List.generate(60, (index) {
                    final isSelected = index == _selectedMinute;
                    return Center(
                      child: Text(
                        index.toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          height: 1.0,
                          leadingDistribution: TextLeadingDistribution.even,
                        ),
                      ),
                    );
                  }),
                ),
                _buildCenterIndicator(theme, height),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyboardInput(ThemeData theme, double height) {
    return Container(
      height: height,
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 72,
            height: 54,
            child: TextField(
              controller: _hourInputController,
              focusNode: _hourFocusNode,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 2,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                  _notifyChanged();
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
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
          SizedBox(
            width: 72,
            height: 54,
            child: TextField(
              controller: _minuteInputController,
              focusNode: _minuteFocusNode,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 2,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                  _notifyChanged();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterIndicator(ThemeData theme, double height) {
    return Center(
      child: GestureDetector(
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
          height: _itemExtent,
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _notifyChanged() {
    widget.onTimeSelected(TimeOfDay(
      hour: _selectedHour,
      minute: _selectedMinute,
    ));
  }
}

Future<TimeScrollPickerResult?> showTimeScrollPicker({
  required BuildContext context,
  int? initialHour,
  int? initialMinute,
}) async {
  return showDialog<TimeScrollPickerResult>(
    context: context,
    builder: (context) {
      return _TimeScrollPickerDialog(
        initialHour: initialHour,
        initialMinute: initialMinute,
      );
    },
  );
}

class TimeScrollPickerResult {
  final int hour;
  final int minute;
  const TimeScrollPickerResult({required this.hour, required this.minute});
}

class _TimeScrollPickerDialog extends StatefulWidget {
  final int? initialHour;
  final int? initialMinute;

  const _TimeScrollPickerDialog({this.initialHour, this.initialMinute});

  @override
  State<_TimeScrollPickerDialog> createState() => _TimeScrollPickerDialogState();
}

class _TimeScrollPickerDialogState extends State<_TimeScrollPickerDialog> {
  int? _selectedHour;
  int? _selectedMinute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  Text(
                    '选择时间',
                    style: theme.textTheme.titleMedium,
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(
                        context,
                        TimeScrollPickerResult(
                          hour: _selectedHour ?? widget.initialHour ?? TimeOfDay.now().hour,
                          minute: _selectedMinute ?? widget.initialMinute ?? TimeOfDay.now().minute,
                        ),
                      );
                    },
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TimeScrollPicker(
                initialHour: widget.initialHour,
                initialMinute: widget.initialMinute,
                onTimeSelected: (time) {
                  _selectedHour = time.hour;
                  _selectedMinute = time.minute;
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
