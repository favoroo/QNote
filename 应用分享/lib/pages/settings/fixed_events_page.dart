import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/models/shortcut_category.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/providers/fixed_event_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/widgets/time_scroll_picker.dart';

class FixedEventsPage extends ConsumerStatefulWidget {
  const FixedEventsPage({super.key});

  @override
  ConsumerState<FixedEventsPage> createState() => _FixedEventsPageState();
}

class _FixedEventsPageState extends ConsumerState<FixedEventsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(fixedEventNotifierProvider.notifier).loadAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final templates = ref.watch(fixedEventNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('固定事件管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showEditDialog(context, null),
          ),
        ],
      ),
      body: templates.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.event_repeat_outlined,
                    size: 48,
                    color: theme.disabledColor,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '暂无固定事件模板',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.disabledColor),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击右上角 + 添加每日固定事件',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
                  ),
                ],
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: templates.length,
              onReorder: (oldIndex, newIndex) {
                ref.read(fixedEventNotifierProvider.notifier).reorder(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                final template = templates[index];
                return _buildTemplateCard(context, template, key: ValueKey(template.id));
              },
            ),
    );
  }

  Widget _buildTemplateCard(BuildContext context, FixedEventTemplate template, {required Key key}) {
    final theme = Theme.of(context);

    return Card(
      key: key,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: ReorderableDragStartListener(
          index: templatesIndexOf(template),
          child: const Icon(Icons.drag_handle),
        ),
        title: Row(
          children: [
            Text(
              template.name,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                template.formattedTimeRange,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        subtitle: template.content != null && template.content!.isNotEmpty
            ? Text(
                template.content!,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: template.isEnabled,
              onChanged: (value) async {
                final updated = template.copyWith(isEnabled: value);
                await ref.read(fixedEventNotifierProvider.notifier).update(updated);
              },
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
          ],
        ),
        onTap: () => _showEditDialog(context, template),
      ),
    );
  }

  int templatesIndexOf(FixedEventTemplate template) {
    final templates = ref.read(fixedEventNotifierProvider);
    return templates.indexWhere((t) => t.id == template.id);
  }

  void _showEditDialog(BuildContext context, FixedEventTemplate? existingTemplate) {
    final isEditing = existingTemplate != null;
    final nameCtl = TextEditingController(text: existingTemplate?.name ?? '');
    final contentCtl = TextEditingController(text: existingTemplate?.content ?? '');

    int startHour = existingTemplate?.startHour ?? 8;
    int startMinute = existingTemplate?.startMinute ?? 0;
    int endHour = existingTemplate?.endHour ?? 12;
    int endMinute = existingTemplate?.endMinute ?? 0;

    // 已选择的标签 ID 列表
    List<String> selectedTagIds = List.from(existingTemplate?.tags ?? []);
    // 每个标签下预设的字段值：tagId -> {fieldKey: fieldValue}
    Map<String, Map<String, dynamic>> selectedTagFields =
        existingTemplate?.tagFields.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v))) ?? {};

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // 获取可用的快捷标签列表
            final shortcutsAsync = ref.watch(shortcutListProvider);

            return shortcutsAsync.when(
              data: (shortcuts) {
                return AlertDialog(
                  title: Text(isEditing ? '编辑固定事件' : '添加固定事件'),
                  scrollable: true,
                  content: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.9,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 名称
                        Text('事件名称', style: Theme.of(context).textTheme.labelSmall),
                        TextField(
                          controller: nameCtl,
                          decoration: const InputDecoration(hintText: '例如：上班'),
                        ),
                        const SizedBox(height: 16),

                        // 开始时间
                        Row(
                          children: [
                            Text('开始时间', style: Theme.of(context).textTheme.labelSmall),
                            const Spacer(),
                            GestureDetector(
                              onTap: () async {
                                final result = await showTimeScrollPicker(
                                  context: context,
                                  initialHour: startHour,
                                  initialMinute: startMinute,
                                );
                                if (result != null) {
                                  setDialogState(() {
                                    startHour = result.hour;
                                    startMinute = result.minute;
                                  });
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // 结束时间
                        Row(
                          children: [
                            Text('结束时间', style: Theme.of(context).textTheme.labelSmall),
                            const Spacer(),
                            GestureDetector(
                              onTap: () async {
                                final result = await showTimeScrollPicker(
                                  context: context,
                                  initialHour: endHour,
                                  initialMinute: endMinute,
                                );
                                if (result != null) {
                                  setDialogState(() {
                                    endHour = result.hour;
                                    endMinute = result.minute;
                                  });
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 关联标签（可选）
                        Text('关联标签（可选）', style: Theme.of(context).textTheme.labelSmall),
                        const SizedBox(height: 6),
                        if (shortcuts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              '暂无可用标签，请先在"快捷按钮管理"中创建',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).disabledColor,
                              ),
                            ),
                          )
                        else
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: shortcuts.map((config) {
                              final isSelected = selectedTagIds.contains(config.id);
                              return GestureDetector(
                                onTap: () {
                                  setDialogState(() {
                                    if (isSelected) {
                                      selectedTagIds.remove(config.id);
                                      selectedTagFields.remove(config.id);
                                    } else {
                                      selectedTagIds.add(config.id);
                                      // 初始化该标签的字段值为空
                                      selectedTagFields.putIfAbsent(config.id, () => {});
                                    }
                                  });
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.transparent
                                          : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.apps,
                                        size: 12,
                                        color: isSelected
                                            ? Theme.of(context).colorScheme.onPrimary
                                            : Theme.of(context).colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        config.name,
                                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: isSelected
                                              ? Theme.of(context).colorScheme.onPrimary
                                              : Theme.of(context).colorScheme.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),

                        // 已选中标签的字段编辑区
                        ..._buildSelectedTagFields(
                          context,
                          shortcuts,
                          selectedTagIds,
                          selectedTagFields,
                          setDialogState,
                        ),

                        const SizedBox(height: 16),

                        // 备注内容
                        Text('备注内容（可选）', style: Theme.of(context).textTheme.labelSmall),
                        TextField(
                          controller: contentCtl,
                          decoration: const InputDecoration(hintText: '例如：上午工作'),
                          maxLines: 2,
                        ),
                      ],
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
                                  content: Text('确定要删除 "${existingTemplate.name}" 吗？'),
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
                                Navigator.pop(ctx);
                                await ref.read(fixedEventNotifierProvider.notifier).delete(existingTemplate.id);
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
                                if (nameCtl.text.isEmpty) {
                                  Toast.warning(context, '请输入事件名称');
                                  return;
                                }
                                final now = DateTime.now();
                                final template = FixedEventTemplate(
                                  id: existingTemplate?.id ?? const Uuid().v4(),
                                  name: nameCtl.text,
                                  startTime:
                                      '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}',
                                  endTime:
                                      '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}',
                                  content: contentCtl.text.isEmpty ? null : contentCtl.text,
                                  tags: selectedTagIds,
                                  tagFields: selectedTagFields,
                                  sortOrder:
                                      existingTemplate?.sortOrder ?? ref.read(fixedEventNotifierProvider).length,
                                  isEnabled: existingTemplate?.isEnabled ?? true,
                                  createdAt: existingTemplate?.createdAt ?? now,
                                  updatedAt: now,
                                );
                                if (isEditing) {
                                  await ref.read(fixedEventNotifierProvider.notifier).update(template);
                                } else {
                                  await ref.read(fixedEventNotifierProvider.notifier).add(template);
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
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => const Center(child: Text('加载标签失败')),
            );
          },
        );
      },
    );
  }

  /// 构建已选中标签的字段编辑区域
  List<Widget> _buildSelectedTagFields(
    BuildContext context,
    List<ShortcutConfig> shortcuts,
    List<String> selectedTagIds,
    Map<String, Map<String, dynamic>> selectedTagFields,
    void Function(void Function()) setDialogState,
  ) {
    if (selectedTagIds.isEmpty) return [];

    final List<Widget> fields = [];
    final theme = Theme.of(context);

    for (final tagId in selectedTagIds) {
      final config = shortcuts.where((s) => s.id == tagId).firstOrNull;
      if (config == null) continue;

      // 该标签当前保存的字段值
      final currentFieldValues = selectedTagFields[tagId] ?? {};

      // 确定要展示的字段列表：优先使用分类下的字段，其次用 config.fields
      List<ShortcutField> fieldsToProcess;
      bool hasCategories = config.categories != null && config.categories!.isNotEmpty;

      if (hasCategories) {
        // 有分类时，先确定当前选中的分类，再用该分类的字段
        final currentCategoryId = currentFieldValues['_category'] as String? ?? '';
        ShortcutCategory currentCategory;
        if (currentCategoryId.isNotEmpty) {
          currentCategory = config.categories!.where((c) => c.id == currentCategoryId).firstOrNull
              ?? config.categories!.first;
        } else {
          currentCategory = config.categories!.first;
        }
        fieldsToProcess = currentCategory.fields;
      } else {
        fieldsToProcess = config.fields;
      }

      // 无字段可编辑则跳过
      if (fieldsToProcess.isEmpty && !hasCategories) continue;

      fields.add(const SizedBox(height: 10));
      fields.add(
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${config.name} 的字段',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
      fields.add(const SizedBox(height: 6));

      // 如果有分类，先展示分类选择器
      if (hasCategories) {
        final currentCategoryId = currentFieldValues['_category'] as String? ?? '';
        fields.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('分类', style: theme.textTheme.labelSmall),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: config.categories!.map((cat) {
                    final isCatSelected = cat.id == currentCategoryId ||
                        (currentCategoryId.isEmpty && cat == config.categories!.first);
                    return GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          selectedTagFields.putIfAbsent(tagId, () => {});
                          // 切换分类时清除该标签之前的字段值（避免残留旧分类的字段）
                          selectedTagFields[tagId] = {'_category': cat.id};
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: isCatSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isCatSelected
                                ? Colors.transparent
                                : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          cat.name,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isCatSelected
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      }

      // 遍历每个字段
      for (final field in fieldsToProcess) {
        final currentValue = currentFieldValues[field.id];

        fields.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(field.label, style: theme.textTheme.labelSmall),
                const SizedBox(height: 3),

                // 根据字段类型渲染不同输入控件
                if (field.type == 'select' && field.options.isNotEmpty)
                  DropdownButtonFormField<String>(
                    value: field.options.contains(currentValue as String?) ? currentValue : null,
                    decoration: InputDecoration(
                      hintText: '选择${field.label}',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    items: field.options.map((opt) {
                      return DropdownMenuItem(value: opt, child: Text(opt));
                    }).toList(),
                    onChanged: (val) {
                      setDialogState(() {
                        selectedTagFields.putIfAbsent(tagId, () => {});
                        if (val == null) {
                          selectedTagFields[tagId]?.remove(field.id);
                        } else {
                          selectedTagFields[tagId]![field.id] = val;
                        }
                      });
                    },
                  )
                else if (field.type == 'multiselect' && field.options.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: field.options.map((opt) {
                      final selectedValues = currentValue is List
                          ? List<String>.from(currentValue)
                          : <String>[];
                      final isSelected = selectedValues.contains(opt);
                      return GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            selectedTagFields.putIfAbsent(tagId, () => {});
                            final vals = List<String>.from(selectedTagFields[tagId]?[field.id] ?? <String>[]);
                            if (isSelected) {
                              vals.remove(opt);
                            } else {
                              vals.add(opt);
                            }
                            selectedTagFields[tagId]![field.id] = vals;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.transparent
                                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            opt,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: isSelected
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  )
                else
                  TextField(
                    controller: TextEditingController(text: currentValue?.toString() ?? ''),
                    onChanged: (val) {
                      setDialogState(() {
                        selectedTagFields.putIfAbsent(tagId, () => {});
                        if (val.isEmpty) {
                          selectedTagFields[tagId]?.remove(field.id);
                        } else {
                          selectedTagFields[tagId]![field.id] = val;
                        }
                      });
                    },
                    decoration: InputDecoration(
                      hintText: '输入${field.label}',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
              ],
            ),
          ),
        );
      }
    }

    return fields;
  }
}