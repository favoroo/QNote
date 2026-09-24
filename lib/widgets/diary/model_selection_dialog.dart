import 'package:flutter/material.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';

export 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart'
    show kAssistantBuiltinModels, assistantModelDisplayName;

/// 统一的时间线/日记模型选择弹窗，供日记页 FAB 长按、输入栏长按、编辑器长按共用。
///
/// 返回值为选中的模型 ID 字符串：
/// - 免费模型返回 `'free:<model-name>'`（例如 `'free:deepseek-flash'`）
/// - 自定义模型返回对应的配置 id（UUID）
class ModelSelectionDialog extends StatelessWidget {
  final List<AiConfig> configs;
  final String? selectedId;

  const ModelSelectionDialog({
    super.key,
    required this.configs,
    this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 解析当前选中的有效 ID（兼容旧的哨兵值 __free_model__）
    final effectiveSelectedId = selectedId == '__free_model__'
        ? 'free:deepseek-flash'
        : (selectedId ?? 'free:deepseek-flash');

    return Dialog(
      backgroundColor: colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '选择模型',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                      child: Text(
                        'QNote 内置免费模型',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ...kAssistantBuiltinModels.map((m) {
                      final isSelected = m['id'] == effectiveSelectedId;
                      return _ModelFreeItem(
                        id: m['id']!,
                        name: m['name']!,
                        isSelected: isSelected,
                        onTap: () => Navigator.pop(context, m['id']),
                      );
                    }),
                    if (configs.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                        child: Text(
                          '自定义模型',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.outline,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      ...configs.map<Widget>((config) {
                        final isSelected = config.id == effectiveSelectedId;
                        return _ModelItem(
                          config: config,
                          isSelected: isSelected,
                          onTap: () => Navigator.pop(context, config.id),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelFreeItem extends StatelessWidget {
  final String id;
  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModelFreeItem({
    required this.id,
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: isSelected
          ? colorScheme.primary.withValues(alpha: 0.05)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 15,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelItem extends StatelessWidget {
  final AiConfig config;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModelItem({
    required this.config,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: isSelected
          ? colorScheme.primary.withValues(alpha: 0.05)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      config.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      '${config.provider} / ${config.modelName}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
