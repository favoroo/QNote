import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/providers/quick_prompt_provider.dart';

/// 常用提示词选择与管理弹窗
///
/// 点击列表项 → 回调 [onSelected] 覆盖填充输入框并关闭弹窗；
/// 弹窗内同时支持新增、编辑、删除提示词（含默认项）。
Future<void> showQuickPromptDialog(
  BuildContext context,
  WidgetRef ref,
  void Function(String text) onSelected,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _QuickPromptDialog(onSelected: onSelected),
  );
}

class _QuickPromptDialog extends ConsumerStatefulWidget {
  const _QuickPromptDialog({required this.onSelected});

  final void Function(String text) onSelected;

  @override
  ConsumerState<_QuickPromptDialog> createState() => _QuickPromptDialogState();
}

class _QuickPromptDialogState extends ConsumerState<_QuickPromptDialog> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final promptsAsync = ref.watch(quickPromptListProvider);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题行
            Row(
              children: [
                Icon(
                  Icons.bolt_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('常用提示词', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _showEditDialog(context, ref, null),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('添加'),
                ),
              ],
            ),
            const Divider(height: 12),
            // 列表区
            promptsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('加载失败：$e'),
              ),
              data: (prompts) {
                if (prompts.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '暂无常用提示词，点击右上角添加',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.4,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: prompts.length,
                    padding: const EdgeInsets.only(bottom: 4),
                    itemBuilder: (context, index) {
                      return _buildPromptRow(
                        context,
                        ref,
                        theme,
                        index,
                        prompts[index],
                      );
                    },
                  ),
                );
              },
            ),
            // 关闭按钮
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单条提示词行：点击文本选中 → 填充输入框；右侧编辑/删除
  Widget _buildPromptRow(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    int index,
    String text,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Icon(
              Icons.circle,
              size: 6,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 10),
          // 点击文本区 → 选中并填充
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                widget.onSelected(text);
                Navigator.of(context).pop();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(text, style: theme.textTheme.bodyMedium),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 20),
            color: theme.colorScheme.onSurfaceVariant,
            tooltip: '编辑',
            onPressed: () =>
                _showEditDialog(context, ref, _EditTarget(index, text)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: theme.colorScheme.error,
            tooltip: '删除',
            onPressed: () => _confirmDelete(context, ref, index, text),
          ),
        ],
      ),
    );
  }

  /// 新增/编辑提示词弹窗
  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    _EditTarget? target,
  ) async {
    final controller = TextEditingController(text: target?.text ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(target == null ? '添加提示词' : '编辑提示词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(hintText: '输入常用提示词内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return;

    if (text.isEmpty) {
      if (!mounted) return;
      Toast.warning(context, '提示词内容不能为空');
      return;
    }

    try {
      final notifier = ref.read(quickPromptListProvider.notifier);
      if (target == null) {
        await notifier.addPrompt(text);
      } else {
        await notifier.updatePrompt(target.index, text);
      }
      if (!mounted) return;
      Toast.success(context, target == null ? '已添加提示词' : '已更新提示词');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  /// 删除提示词（二次确认）
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    int index,
    String text,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除提示词'),
        content: Text('确定删除「$text」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(quickPromptListProvider.notifier).deletePrompt(index);
      if (!mounted) return;
      Toast.success(context, '已删除提示词');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '删除失败：$e');
    }
  }
}

/// 编辑目标：索引 + 原文本
class _EditTarget {
  const _EditTarget(this.index, this.text);

  final int index;
  final String text;
}
