import 'package:flutter/material.dart';
import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 一个可选项：`effort == null` 表示「自动」
class ReasoningEffortOption {
  final ReasoningEffort? effort;
  final String label;
  final String description;

  const ReasoningEffortOption({
    required this.effort,
    required this.label,
    required this.description,
  });
}

/// 弹层返回值
///
/// 用包装类而不是裸 `ReasoningEffort?`：底部弹层取消时也返回 null，
/// 与「选择自动」无法区分。
class ReasoningEffortSelection {
  final ReasoningEffort? effort;

  const ReasoningEffortSelection(this.effort);
}

/// 当前模型可选的思考强度（首项固定为「自动」）
///
/// 能力表未收录的模型返回通用兜底档位，而不是空列表：参考 ZCode 的做法，
/// 用户总能自己调；弹层里会标注「通用参数」，选错了由发信层的 400 降级兜住。
List<ReasoningEffortOption> reasoningEffortOptions({
  required String modelName,
  required String providerType,
  String? vendorId,
}) {
  final capability = ModelReasoningCapability.forUi(
    modelName: modelName,
    providerType: providerType,
    vendorId: vendorId,
  );

  return [
    const ReasoningEffortOption(
      effort: null,
      label: '自动',
      description: '不额外干预，由模型服务决定',
    ),
    for (final effort in capability.levels)
      ReasoningEffortOption(
        effort: effort,
        label: capability.labelFor(effort),
        description: _descriptionFor(effort),
      ),
  ];
}

String _descriptionFor(ReasoningEffort effort) {
  switch (effort) {
    case ReasoningEffort.none:
      return '不额外投入思考，响应最快';
    case ReasoningEffort.low:
      return '少量思考，响应与质量折中';
    case ReasoningEffort.medium:
      return '较充分的思考，适合大多数任务';
    case ReasoningEffort.high:
      return '最充分的思考，复杂任务更稳但更慢';
  }
}

/// 共享思考强度选择器：底部弹层
///
/// 返回值：null 表示用户取消；[ReasoningEffortSelection.effort] 为 null 表示自动。
Future<ReasoningEffortSelection?> showReasoningEffortSheet(
  BuildContext context, {
  required String modelName,
  required String providerType,
  String? vendorId,
  ReasoningEffort? selected,
}) {
  return showModalBottomSheet<ReasoningEffortSelection>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ReasoningEffortSheet(
      modelName: modelName,
      providerType: providerType,
      vendorId: vendorId,
      selected: selected,
    ),
  );
}

class ReasoningEffortSheet extends StatelessWidget {
  final String modelName;
  final String providerType;
  final String? vendorId;
  final ReasoningEffort? selected;

  const ReasoningEffortSheet({
    super.key,
    required this.modelName,
    required this.providerType,
    this.vendorId,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capability = ModelReasoningCapability.forUi(
      modelName: modelName,
      providerType: providerType,
      vendorId: vendorId,
    );
    final options = reasoningEffortOptions(
      modelName: modelName,
      providerType: providerType,
      vendorId: vendorId,
    );

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '思考强度',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                // 未收录模型也给出入口，但必须说明参数是猜的，
                // 避免用户以为「选了没反应」是 App 的问题
                if (capability.isGeneric) ...[
                  const SizedBox(height: 6),
                  Text(
                    '未收录该模型的思考参数，按 OpenAI 兼容通用字段发送；'
                    '接口不支持时会自动忽略',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: options.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
              itemBuilder: (context, index) {
                final option = options[index];
                final isSelected = option.effort == selected;
                return ListTile(
                  leading: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  title: Text(option.label),
                  subtitle: Text(option.description),
                  onTap: () => Navigator.pop(
                    context,
                    ReasoningEffortSelection(option.effort),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
