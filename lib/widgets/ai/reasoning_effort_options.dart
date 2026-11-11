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

/// 当前模型可选的思考强度（首项固定为「自动」）
///
/// 档位来源优先用模型配置里自定义的集合；没有自定义时按模型族自动识别。
/// 能力表未收录的模型返回通用兜底档位，而不是空列表：参考 ZCode 的做法，
/// 用户总能自己调；弹层里会标注「通用参数」，选错了由发信层的 400 降级兜住。
List<ReasoningEffortOption> reasoningEffortOptions({
  required String modelName,
  required String providerType,
  String? vendorId,
  List<ReasoningEffort>? customLevels,
}) {
  final capability = ModelReasoningCapability.forUi(
    modelName: modelName,
    providerType: providerType,
    vendorId: vendorId,
    customLevels: customLevels,
  );

  return [
    const ReasoningEffortOption(
      effort: null,
      label: '自动',
      description: '由模型服务决定',
    ),
    for (final effort in capability.levels)
      ReasoningEffortOption(
        effort: effort,
        label: capability.labelFor(effort),
        description: effort.description,
      ),
  ];
}
