import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// 弹出小Q人机交互确认弹窗
///
/// 返回用户选择的选项文本或自定义输入的文字。如果用户取消或关闭弹窗，则返回 null。
Future<String?> showAskUserDialog({
  required BuildContext context,
  required String question,
  List<String>? options,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => AskUserDialog(
      question: question,
      options: options,
    ),
  );
}

/// 小Q人机交互确认与提问弹窗组件
class AskUserDialog extends StatefulWidget {
  final String question;
  final List<String>? options;

  const AskUserDialog({
    super.key,
    required this.question,
    this.options,
  });

  @override
  State<AskUserDialog> createState() => _AskUserDialogState();
}

class _AskUserDialogState extends State<AskUserDialog> {
  String? _selectedOption;
  late final TextEditingController _customInputController;
  bool _showCustomInput = false;

  @override
  void initState() {
    super.initState();
    _customInputController = TextEditingController();
    // 默认如果 options 存在且非空，先不强制选中或默认选中第一个积极选项
    if (widget.options != null && widget.options!.isNotEmpty) {
      _selectedOption = widget.options!.first;
    } else {
      _showCustomInput = true;
    }
  }

  @override
  void dispose() {
    _customInputController.dispose();
    super.dispose();
  }

  /// 判断问题是否具有危险/不可逆特征（如删除、清空等）
  bool get _isDestructive {
    final lower = widget.question.toLowerCase();
    return lower.contains('删除') ||
        lower.contains('清空') ||
        lower.contains('移除') ||
        lower.contains('销毁') ||
        lower.contains('delete') ||
        lower.contains('remove');
  }

  void _submit() {
    final customText = _customInputController.text.trim();
    if (customText.isNotEmpty) {
      Navigator.of(context).pop(customText);
      return;
    }
    if (_selectedOption != null) {
      Navigator.of(context).pop(_selectedOption);
      return;
    }
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final options = widget.options ?? [];

    final isDestructive = _isDestructive;
    final primaryColor = isDestructive ? colorScheme.error : colorScheme.primary;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDestructive
                  ? colorScheme.errorContainer.withValues(alpha: 0.5)
                  : colorScheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isDestructive ? Icons.warning_amber_rounded : Icons.smart_toy_outlined,
              size: 22,
              color: primaryColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isDestructive ? '操作确认' : '小Q向您确认',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 460,
          maxHeight: 480,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 问题 Markdown 呈现
              MarkdownBody(
                data: widget.question,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: colorScheme.onSurface,
                  ),
                  strong: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isDestructive ? colorScheme.error : colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 可选的快捷选项列表
              if (options.isNotEmpty) ...[
                Text(
                  '请选择处理方式：',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: options.map((option) {
                    final isSelected = _selectedOption == option && !_showCustomInput;
                    final isOptionDestructive = option.contains('删除') ||
                        option.contains('清空') ||
                        option.contains('移除');

                    return ChoiceChip(
                      label: Text(option),
                      selected: isSelected,
                      selectedColor: isOptionDestructive
                          ? colorScheme.errorContainer
                          : colorScheme.primaryContainer,
                      labelStyle: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        color: isSelected
                            ? (isOptionDestructive
                                ? colorScheme.onErrorContainer
                                : colorScheme.onPrimaryContainer)
                            : colorScheme.onSurface,
                      ),
                      onSelected: (selected) {
                        // 点击选项直接触发确认并关闭弹窗，提供符合直觉的单步确认体验
                        Navigator.of(context).pop(option);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
              ],

              // 自定义回复展开折叠
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  setState(() {
                    _showCustomInput = !_showCustomInput;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        _showCustomInput ? Icons.arrow_drop_down : Icons.arrow_right,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      Text(
                        _showCustomInput ? '收起自定义输入' : '补充其他说明/自定义回复',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (_showCustomInput) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customInputController,
                  autofocus: options.isEmpty,
                  maxLines: 2,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: '输入您的指令或回复...',
                    hintStyle: TextStyle(fontSize: 13, color: colorScheme.outline),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    isDense: true,
                    contentPadding: const EdgeInsets.all(12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: primaryColor, width: 1.5),
                    ),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => _submit(),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(
            '取消',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
        FilledButton(
          style: isDestructive
              ? FilledButton.styleFrom(
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                )
              : null,
          onPressed: _submit,
          child: const Text('确认'),
        ),
      ],
    );
  }
}
