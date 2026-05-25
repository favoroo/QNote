import 'package:flutter/material.dart';

Future<List<String>?> showTagPickerDialog({
  required BuildContext context,
  required List<String> availableTags,
  required List<String> selectedTags,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (context) => _TagPickerDialog(
      availableTags: availableTags,
      selectedTags: selectedTags,
    ),
  );
}

class _TagPickerDialog extends StatefulWidget {
  final List<String> availableTags;
  final List<String> selectedTags;

  const _TagPickerDialog({
    required this.availableTags,
    required this.selectedTags,
  });

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.selectedTags);
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else {
        _selected.add(tag);
      }
    });
  }

  void _clearAll() {
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Text('选择标签', style: theme.textTheme.titleLarge),
          const Spacer(),
          TextButton(
            onPressed: _clearAll,
            child: const Text('清除'),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: widget.availableTags.map((tag) {
            final isSelected = _selected.contains(tag);
            return FilterChip(
              label: Text(tag),
              selected: isSelected,
              onSelected: (_) => _toggleTag(tag),
              showCheckmark: true,
              selectedColor: colorScheme.primaryContainer,
              checkmarkColor: colorScheme.onPrimaryContainer,
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
