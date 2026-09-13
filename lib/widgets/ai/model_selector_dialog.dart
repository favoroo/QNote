import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';

/// 小Q可用的内置免费模型（id 带 free: 前缀，裸名为 CPA 模型表 alias）
const List<Map<String, String>> kAssistantBuiltinModels = [
  {'id': 'free:claude-sonnet-4-6', 'name': '内置 Claude Sonnet 4.6'},
  {'id': 'free:gemini-3.5-flash-lite', 'name': '内置 Gemini 3.5 Flash Lite'},
  {'id': 'free:gemini-3.8-flash-low', 'name': '内置 Gemini 3.8 Flash Low'},
  {'id': 'free:sensenova-flash-lite', 'name': '内置 SenseNova 6.8'},
  {'id': 'free:glm-5.2', 'name': '内置 GLM 5.2'},
  {'id': 'free:deepseek-v4-flash', 'name': '内置 DeepSeek V4 Flash'},
];

/// 模型 id → 显示名：free: 前缀查内置表，未收录时回退裸 id；自定义配置查 name
String? assistantModelDisplayName(String? id, List<AiConfig> configs) {
  if (id == null) return null;
  // 哨兵值：未绑定任何模型时视为使用默认免费模型
  if (id == '__free_model__') return '内置 Gemini 3.5 Flash Lite';
  if (id.startsWith('free:')) {
    for (final m in kAssistantBuiltinModels) {
      if (m['id'] == id) return m['name'];
    }
    return id.substring(5);
  }
  for (final config in configs) {
    if (config.id == id) return config.name;
  }
  return id;
}

/// 弹出小Q模型选择弹窗（AI 主页面与悬浮小Q面板共用入口）。
///
/// 选中且与当前不同时写入全局 `AiRoles.assistant` 角色绑定并刷新
/// [aiRolesProvider]，返回选中项（id + 显示名）；取消或未变更返回 null。
/// 两处界面共用同一角色设置，任一处切换即全局生效。
Future<({String id, String name})?> showAssistantModelSelector(
  BuildContext context,
  WidgetRef ref,
) async {
  final configs = await ref.read(aiConfigListProvider.future);
  if (!context.mounted) return null;
  final roles = await ref.read(aiRolesProvider.future);
  if (!context.mounted) return null;
  // 从角色绑定推导当前选中模型 id；均未绑定时用哨兵值高亮默认免费模型
  final activeModelId = (roles?.assistantUseFreeModel ?? false)
      ? 'free:${roles!.assistantFreeModelId ?? 'gemini-3.5-flash-lite'}'
      : roles?.assistant ?? '__free_model__';
  final selected = await showDialog<String>(
    context: context,
    builder: (ctx) =>
        ModelSelectorDialog(configs: configs, activeModelId: activeModelId),
  );
  if (selected == null || selected == activeModelId) return null;
  final isFree = selected.startsWith('free:');
  // copyWith 哨兵语义：只改 assistant 三元组，timeline/生图绑定等原字段保留
  final newRoles = (roles ?? const AiRoles()).copyWith(
    // 切换到免费模型时显式传 null 清空自定义配置绑定，反之亦然
    assistant: isFree ? null : selected,
    assistantUseFreeModel: isFree,
    assistantFreeModelId: isFree ? selected.substring(5) : null,
  );
  await saveAiRoles(newRoles);
  ref.invalidate(aiRolesProvider);
  return (
    id: selected,
    name: assistantModelDisplayName(selected, configs) ?? selected,
  );
}

/// 小Q模型选择弹窗：内置免费模型 + 用户自定义配置，单选 radio 样式，
/// 选中项通过 `Navigator.pop(context, id)` 返回
class ModelSelectorDialog extends StatelessWidget {
  final List<AiConfig> configs;
  final String? activeModelId;
  const ModelSelectorDialog({
    super.key,
    required this.configs,
    required this.activeModelId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SimpleDialog(
      title: const Text('选择小Q模型'),
      children: [
        ...kAssistantBuiltinModels.map((m) {
          final isSelected = activeModelId == m['id'] ||
              (activeModelId == '__free_model__' &&
                  m['id'] == 'free:gemini-3.5-flash-lite');
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, m['id']),
            child: Row(
              children: [
                Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m['name']!,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isSelected ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        ...configs.map((config) {
          final isActive = config.id == activeModelId;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, config.id),
            child: Row(
              children: [
                Icon(
                  isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isActive ? theme.colorScheme.primary : null,
                        ),
                      ),
                      Text(
                        '${config.provider} / ${config.modelName}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
