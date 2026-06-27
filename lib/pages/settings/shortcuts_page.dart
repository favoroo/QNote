import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

class ShortcutsPage extends ConsumerStatefulWidget {
  const ShortcutsPage({super.key});

  @override
  ConsumerState<ShortcutsPage> createState() => _ShortcutsPageState();
}

class _ShortcutsPageState extends ConsumerState<ShortcutsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(shortcutListNotifierProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = ref.watch(shortcutListNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('快捷按钮管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showEditDialog(context, null),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: shortcuts.isEmpty
                ? Center(
                    child: Text(
                      '暂无快捷按钮，点击右上角 + 添加',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.disabledColor),
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: shortcuts.length,
                    onReorder: (oldIndex, newIndex) {
                      ref.read(shortcutListNotifierProvider.notifier).reorder(oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      final config = shortcuts[index];
                      return _buildShortcutCard(context, config, key: ValueKey(config.id));
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24, top: 8),
            child: Container(
              width: double.infinity,
              height: 54,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _confirmAndRestoreDefaults(context),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.refresh, size: 20, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Text(
                        '恢复默认设置',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndRestoreDefaults(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认设置'),
        content: const Text('确定要恢复默认快捷按钮设置吗？此操作将覆盖您当前所有的自定义快捷按钮配置，且不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('恢复'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(shortcutListNotifierProvider.notifier).restoreDefaults();
      if (context.mounted) {
        Toast.success(context, '已成功恢复默认快捷按钮设置');
      }
    }
  }

  Widget _buildShortcutCard(BuildContext context, ShortcutConfig config, {required Key key}) {
    final theme = Theme.of(context);
    final fieldCount = config.fields.length + (config.categories?.fold<int>(0, (sum, c) => sum + c.fields.length) ?? 0);

    return Card(
      key: key,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: ReorderableDragStartListener(
          index: shortcutsIndexOf(config),
          child: const Icon(Icons.drag_handle),
        ),
        title: Text(
          config.name,
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        subtitle: Row(
          children: [
            Text('$fieldCount 个字段', style: theme.textTheme.bodySmall),
            if (config.hasPopup) ...[
              const SizedBox(width: 8),
              Icon(Icons.open_in_new, size: 12, color: theme.colorScheme.primary),
              Text('弹窗', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: config.isVisible,
              onChanged: (value) async {
                final updated = config.copyWith(isVisible: value);
                await ref.read(shortcutListNotifierProvider.notifier).update(updated);
              },
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
          ],
        ),
        onTap: () => _showEditDialog(context, config),
      ),
    );
  }

  int shortcutsIndexOf(ShortcutConfig config) {
    final shortcuts = ref.read(shortcutListNotifierProvider);
    return shortcuts.indexWhere((s) => s.id == config.id);
  }

  void _showEditDialog(BuildContext context, ShortcutConfig? existingConfig) {
    final isEditing = existingConfig != null;
    final nameCtl = TextEditingController(text: existingConfig?.name ?? '');
    bool hasPopup = existingConfig?.hasPopup ?? false;
    List<ShortcutField> fields = existingConfig != null
        ? existingConfig.fields.map((f) => f.copyWith()).toList()
        : [];
    List<ShortcutCategory> categories = existingConfig != null
        ? (existingConfig.categories?.map((c) => c.copyWith(
            fields: c.fields.map((f) => f.copyWith()).toList(),
          )).toList() ?? [])
        : [];

    int activeCategoryIdx = 0;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(isEditing ? '编辑快捷按钮' : '添加快捷按钮'),
              scrollable: true,
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.9,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('名称', style: Theme.of(context).textTheme.labelSmall),
                      TextField(controller: nameCtl, decoration: const InputDecoration(hintText: '例如：睡眠')),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: Text('启用弹窗配置', style: Theme.of(context).textTheme.bodyMedium)),
                          Switch(
                            value: hasPopup,
                            onChanged: (v) => setDialogState(() => hasPopup = v),
                          ),
                        ],
                      ),
                      const Divider(),
                      Row(
                        children: [
                          Expanded(child: Text('启用多分类模式', style: Theme.of(context).textTheme.bodyMedium)),
                          Switch(
                            value: categories.isNotEmpty,
                            onChanged: (v) {
                              setDialogState(() {
                                if (v && categories.isEmpty) {
                                  categories.add(ShortcutCategory(id: const Uuid().v4(), name: '新分类', fields: []));
                                } else if (!v) {
                                  categories.clear();
                                }
                              });
                            },
                          ),
                        ],
                      ),
                      if (categories.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text('分类管理', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                            const Spacer(),
                            TextButton.icon(
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加分类'),
                              onPressed: () {
                                setDialogState(() {
                                  categories.add(ShortcutCategory(
                                    id: const Uuid().v4(),
                                    name: '新分类',
                                    fields: [],
                                  ));
                                  activeCategoryIdx = categories.length - 1;
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: categories.asMap().entries.map((entry) {
                              final idx = entry.key;
                              final cat = entry.value;
                              final isSelected = idx == activeCategoryIdx;
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(cat.name.isEmpty ? '未命名' : cat.name),
                                  selected: isSelected,
                                  onSelected: (v) {
                                    if (v) setDialogState(() => activeCategoryIdx = idx);
                                  },
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (activeCategoryIdx < categories.length)
                          _buildCategoryEditor(
                            context,
                            category: categories[activeCategoryIdx],
                            onChanged: (updatedCat) {
                              setDialogState(() {
                                categories[activeCategoryIdx] = updatedCat;
                              });
                            },
                            onDelete: () {
                              setDialogState(() {
                                categories.removeAt(activeCategoryIdx);
                                if (activeCategoryIdx >= categories.length) {
                                  activeCategoryIdx = categories.length - 1;
                                }
                                if (activeCategoryIdx < 0) activeCategoryIdx = 0;
                              });
                            },
                          ),
                      ] else ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text('字段管理', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                            const Spacer(),
                            TextButton.icon(
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加字段'),
                              onPressed: () {
                                setDialogState(() {
                                  fields.add(ShortcutField(
                                    id: const Uuid().v4(),
                                    label: '',
                                    type: 'input',
                                    options: [],
                                  ));
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...fields.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final field = entry.value;
                          return _buildFieldEditor(
                            context,
                            field: field,
                            onChanged: (updatedField) {
                              setDialogState(() {
                                fields[idx] = updatedField;
                              });
                            },
                            onDelete: () {
                              setDialogState(() {
                                fields.removeAt(idx);
                              });
                            },
                          );
                        }),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isEditing)
                      TextButton(
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx2) => AlertDialog(
                              title: const Text('确认删除'),
                              content: Text('确定要删除 "${existingConfig.name}" 吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx2, false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx2, true),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Theme.of(context).colorScheme.error,
                                  ),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && context.mounted) {
                            Navigator.pop(ctx); // Close edit dialog
                            await ref.read(shortcutListNotifierProvider.notifier).delete(existingConfig.id);
                            if (context.mounted) {
                              Toast.success(context, '已删除');
                            }
                          }
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        child: const Text('删除'),
                      )
                    else
                      const SizedBox.shrink(),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            final now = DateTime.now();
                            final config = ShortcutConfig(
                              id: existingConfig?.id ?? const Uuid().v4(),
                              name: nameCtl.text.isEmpty ? '未命名' : nameCtl.text,
                              hasPopup: hasPopup,
                              fields: fields,
                              categories: categories.isNotEmpty ? categories : null,
                              sortOrder: existingConfig?.sortOrder ?? ref.read(shortcutListNotifierProvider).length,
                              isVisible: existingConfig?.isVisible ?? true,
                              createdAt: existingConfig?.createdAt ?? now,
                              updatedAt: now,
                            );
                            if (isEditing) {
                              await ref.read(shortcutListNotifierProvider.notifier).update(config);
                            } else {
                              await ref.read(shortcutListNotifierProvider.notifier).add(config);
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildFieldEditor(
    BuildContext context, {
    required ShortcutField field,
    required ValueChanged<ShortcutField> onChanged,
    required VoidCallback onDelete,
  }) {
    final theme = Theme.of(context);
    const fieldTypeMap = {
      'input': '文本',
      'number': '数字',
      'select': '单选',
      'multi-select': '多选',
      'time': '时间',
      'water-amount': '喝水量',
    };
    final labelCtl = TextEditingController(text: field.label);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.drag_indicator, size: 16, color: theme.disabledColor),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('名称', style: theme.textTheme.labelSmall?.copyWith(color: theme.disabledColor)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: labelCtl,
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                        decoration: InputDecoration(
                          hintText: '字段名',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                        onChanged: (v) => onChanged(field.copyWith(label: v)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('类型', style: theme.textTheme.labelSmall?.copyWith(color: theme.disabledColor)),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(
                          value: fieldTypeMap.containsKey(field.type) ? field.type : 'input',
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          icon: const Icon(Icons.keyboard_arrow_down, size: 16),
                          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                          items: fieldTypeMap.entries.map((e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          )).toList(),
                          onChanged: (v) {
                            if (v != null) onChanged(field.copyWith(type: v));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: theme.colorScheme.error.withValues(alpha: 0.7),
                  onPressed: onDelete,
                ),
              ],
            ),
            if (field.type == 'select' || field.type == 'multi-select') ...[
              const SizedBox(height: 12),
              Text('选项', style: theme.textTheme.labelSmall?.copyWith(color: theme.disabledColor)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ...field.options.asMap().entries.map((entry) {
                      final optIdx = entry.key;
                      final opt = entry.value;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: theme.colorScheme.outlineVariant),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.drag_indicator, size: 12, color: theme.disabledColor),
                            const SizedBox(width: 4),
                            Text(opt, style: theme.textTheme.bodySmall),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () {
                                final opts = List<String>.from(field.options);
                                opts.removeAt(optIdx);
                                onChanged(field.copyWith(options: opts));
                              },
                              child: Icon(Icons.close, size: 12, color: theme.disabledColor),
                            ),
                          ],
                        ),
                      );
                    }),
                    GestureDetector(
                      onTap: () async {
                        final result = await _showAddOptionDialog(context);
                        if (result != null && result.isNotEmpty) {
                          onChanged(field.copyWith(options: [...field.options, result]));
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
                        ),
                        child: Icon(Icons.add, size: 12, color: theme.colorScheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Switch(
                    value: field.allowCustom,
                    onChanged: (v) => onChanged(field.copyWith(allowCustom: v)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 4),
                  Text('允许自定义输入', style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<String?> _showAddOptionDialog(BuildContext context) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加选项'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '选项内容'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('添加')),
        ],
      ),
    );
  }

  Widget _buildCategoryEditor(
    BuildContext context, {
    required ShortcutCategory category,
    required ValueChanged<ShortcutCategory> onChanged,
    required VoidCallback onDelete,
  }) {
    final nameCtl = TextEditingController(text: category.name);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                    labelText: '分类名称',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => onChanged(category.copyWith(name: v)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('字段管理', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 14),
                label: const Text('添加字段'),
                onPressed: () {
                  final updatedFields = List<ShortcutField>.from(category.fields);
                  updatedFields.add(ShortcutField(
                    id: const Uuid().v4(),
                    label: '',
                    type: 'input',
                    options: [],
                  ));
                  onChanged(category.copyWith(fields: updatedFields));
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...category.fields.asMap().entries.map((entry) {
            final fieldIdx = entry.key;
            final field = entry.value;
            return _buildFieldEditor(
              context,
              field: field,
              onChanged: (updatedField) {
                final updatedFields = List<ShortcutField>.from(category.fields);
                updatedFields[fieldIdx] = updatedField;
                onChanged(category.copyWith(fields: updatedFields));
              },
              onDelete: () {
                final updatedFields = List<ShortcutField>.from(category.fields);
                updatedFields.removeAt(fieldIdx);
                onChanged(category.copyWith(fields: updatedFields));
              },
            );
          }),
        ],
      ),
    );
  }
}
