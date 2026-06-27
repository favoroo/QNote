import 'package:flutter/material.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';

class EditTagTimeSheet extends StatefulWidget {
  final TagEntry entry;

  const EditTagTimeSheet({super.key, required this.entry});

  @override
  State<EditTagTimeSheet> createState() => _EditTagTimeSheetState();
}

class _EditTagTimeSheetState extends State<EditTagTimeSheet> {
  int? _startHour;
  int? _startMinute;
  int? _startOffset;
  int? _endHour;
  int? _endMinute;
  int? _endOffset;

  @override
  void initState() {
    super.initState();
    _startHour = widget.entry.startHour;
    _startMinute = widget.entry.startMinute;
    _startOffset = widget.entry.startOffset ?? 0;
    _endHour = widget.entry.endHour;
    _endMinute = widget.entry.endMinute;
    _endOffset = widget.entry.endOffset ?? 0;

    // Default start time to now if not set
    if (_startHour == null || _startMinute == null) {
      final now = TimeOfDay.now();
      _startHour = now.hour;
      _startMinute = now.minute;
    }
  }

  String _formatTime(int hour, int minute) {
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar for bottom sheet
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '编辑 ${widget.entry.name} 时间',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, {'clear': true}),
                      child: Text(
                        '清除时间',
                        style: TextStyle(
                          color: colorScheme.error,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      style: IconButton.styleFrom(
                        backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Start Time Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '开始时间',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: () async {
                            final res = await showTimeScrollPicker(
                              context: context,
                              initialHour: _startHour,
                              initialMinute: _startMinute,
                            );
                            if (res != null) {
                              setState(() {
                                _startHour = res.hour;
                                _startMinute = res.minute;
                              });
                            }
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _formatTime(_startHour!, _startMinute!),
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.edit,
                                size: 14,
                                color: colorScheme.primary.withValues(alpha: 0.7),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Offset toggle
                  ChoiceChip(
                    label: const Text('前一天'),
                    selected: _startOffset == -1,
                    onSelected: (selected) {
                      setState(() {
                        _startOffset = selected ? -1 : 0;
                      });
                    },
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _startOffset == -1 ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                    ),
                    selectedColor: colorScheme.primary,
                    checkmarkColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // End Time Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '结束时间',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_endHour == null)
                          TextButton.icon(
                            onPressed: () async {
                              final res = await showTimeScrollPicker(
                                context: context,
                                initialHour: _startHour,
                                initialMinute: _startMinute,
                              );
                              if (res != null) {
                                setState(() {
                                  _endHour = res.hour;
                                  _endMinute = res.minute;
                                  _endOffset = 0;
                                });
                              }
                            },
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('添加结束时间'),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              foregroundColor: colorScheme.primary,
                              textStyle: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () async {
                              final res = await showTimeScrollPicker(
                                context: context,
                                initialHour: _endHour,
                                initialMinute: _endMinute,
                              );
                              if (res != null) {
                                setState(() {
                                  _endHour = res.hour;
                                  _endMinute = res.minute;
                                });
                              }
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _formatTime(_endHour!, _endMinute!),
                                  style: theme.textTheme.headlineMedium?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.edit,
                                  size: 14,
                                  color: colorScheme.primary.withValues(alpha: 0.7),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_endHour != null) ...[
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      color: colorScheme.error,
                      onPressed: () {
                        setState(() {
                          _endHour = null;
                          _endMinute = null;
                          _endOffset = 0;
                        });
                      },
                      style: IconButton.styleFrom(
                        backgroundColor: colorScheme.error.withValues(alpha: 0.08),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ChoiceChip(
                      label: const Text('后一天'),
                      selected: _endOffset == 1,
                      onSelected: (selected) {
                        setState(() {
                          _endOffset = selected ? 1 : 0;
                        });
                      },
                      labelStyle: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _endOffset == 1 ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                      ),
                      selectedColor: colorScheme.primary,
                      checkmarkColor: colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(context, {
                        'startHour': _startHour,
                        'startMinute': _startMinute,
                        'startOffset': _startOffset,
                        'endHour': _endHour,
                        'endMinute': _endMinute,
                        'endOffset': _endOffset,
                      });
                    },
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
