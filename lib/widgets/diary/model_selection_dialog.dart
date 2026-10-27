import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

export 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart'
    show aiModelDisplayName;

/// 统一的时间线/日记「AI 提取模型」选择弹层
///
/// 供日记页 FAB 长按、输入栏长按、编辑器长按共用：选中即写入
/// `AiRoles.timelineOptimization` 绑定并刷新 [aiRolesProvider]。
/// 返回选中的展示名；取消或未变更返回 null；无可用模型时弹添加引导。
Future<String?> showTimelineModelSelector(
  BuildContext context,
  WidgetRef ref,
) async {
  final providers = await ref.read(aiProviderListProvider.future);
  if (!context.mounted) return null;

  if (enabledModelEntries(providers).isEmpty) {
    await showNoModelConfiguredDialog(context, scene: '切换时间线提取模型');
    return null;
  }

  final roles = await ref.read(aiRolesProvider.future);
  if (!context.mounted) return null;
  final current = roles?.timelineOptimization;
  final result = await showModelPickerSheet(
    context,
    providers: providers,
    selected: current,
    title: '选择提取模型',
    allowUnbind: current != null,
  );
  if (result == null || result.ref == current) return null;

  await AiRoleService.instance.bindRole('timelineOptimization', result.ref);
  ref.invalidate(aiRolesProvider);

  return _displayNameForRef(result.ref, providers);
}

/// 当前生效的时间线模型展示名（绑定失效时回落到默认厂商的首个模型）
Future<String> timelineModelDisplayName(WidgetRef ref) async {
  final providers = await ref.read(aiProviderListProvider.future);
  final roles = await ref.read(aiRolesProvider.future);
  final bound = roles?.timelineOptimization;
  if (bound != null &&
      providers.any(
        (p) => p.id == bound.providerId && p.hasModel(bound.modelName),
      )) {
    return aiModelDisplayName(bound, providers);
  }
  return _displayNameForRef(null, providers);
}

String _displayNameForRef(AiModelRef? ref, List<AiProvider> providers) {
  if (ref != null) return aiModelDisplayName(ref, providers);
  final provider = providers.where((p) => p.isDefault && p.isUsable).firstOrNull ??
      providers.where((p) => p.isUsable).firstOrNull;
  return provider?.firstModel?.name ?? '未配置模型';
}