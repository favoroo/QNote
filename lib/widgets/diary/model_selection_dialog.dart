import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

export 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart'
    show aiBindingDisplayName, aiModelDisplayName, defaultModelRef;

/// 统一的时间线/日记「AI 提取模型」选择弹层
///
/// 供日记页 FAB 长按、输入栏长按、编辑器长按共用：选中即写入
/// `AiRoles.timelineOptimization` 绑定并刷新 [aiRolesProvider]。
/// 可选项同时包含具体模型与模型路由组（组内模型轮换可分散提取调用限流）。
/// 返回选中的展示名；取消或未变更返回 null；无可用模型时弹添加引导。
Future<String?> showTimelineModelSelector(
  BuildContext context,
  WidgetRef ref,
) async {
  final providers = await ref.read(aiProviderListProvider.future);
  final groups = await ref.read(aiRouteGroupListProvider.future);
  if (!context.mounted) return null;

  if (enabledModelEntries(providers).isEmpty && groups.isEmpty) {
    await showNoModelConfiguredDialog(context, scene: '切换时间线提取模型');
    return null;
  }

  final roles = await ref.read(aiRolesProvider.future);
  if (!context.mounted) return null;
  final current = roles?.timelineOptimization;
  final effective = isBindingUsable(current, providers, groups)
      ? current
      : defaultModelRef(providers);
  final result = await showModelPickerSheet(
    context,
    providers: providers,
    groups: groups,
    selected: effective,
    title: '选择提取模型',
  );
  if (result == null || result.ref == current) return null;

  await AiRoleService.instance.bindRole('timelineOptimization', result.ref);
  ref.invalidate(aiRolesProvider);

  return aiBindingDisplayName(result.ref, providers, groups);
}

/// 当前生效的时间线模型展示名（绑定失效时回落到默认厂商的首个模型）
Future<String> timelineModelDisplayName(WidgetRef ref) async {
  final providers = await ref.read(aiProviderListProvider.future);
  final groups = await ref.read(aiRouteGroupListProvider.future);
  final roles = await ref.read(aiRolesProvider.future);
  final bound = roles?.timelineOptimization;
  if (isBindingUsable(bound, providers, groups)) {
    return aiBindingDisplayName(bound, providers, groups);
  }
  return _defaultDisplayName(providers);
}

String _defaultDisplayName(List<AiProvider> providers) {
  final provider = providers.where((p) => p.isDefault && p.isUsable).firstOrNull ??
      providers.where((p) => p.isUsable).firstOrNull;
  return provider?.firstModel?.name ?? '未配置模型';
}
