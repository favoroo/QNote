import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

export 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart'
    show aiModelDisplayName, enabledModelEntries;

/// 弹出小Q 对话模型选择弹层（AI 主页面与悬浮小Q 面板共用入口）
///
/// 选中且与当前不同时写入全局 `AiRoles.assistant` 角色绑定并刷新
/// [aiRolesProvider]，返回选中项（ref + 展示名）；取消或未变更返回 null。
/// 两处界面共用同一角色设置，任一处切换即全局生效。
///
/// 一个已启用模型都没有时不做选择器，直接弹「去添加模型」引导。
Future<({AiModelRef? ref, String name})?> showAssistantModelSelector(
  BuildContext context,
  WidgetRef ref,
) async {
  final providers = await ref.read(aiProviderListProvider.future);
  if (!context.mounted) return null;

  if (enabledModelEntries(providers).isEmpty) {
    await showNoModelConfiguredDialog(context, scene: '切换小Q模型');
    return null;
  }

  final roles = await ref.read(aiRolesProvider.future);
  if (!context.mounted) return null;
  final current = roles?.assistant;
  final result = await showModelPickerSheet(
    context,
    providers: providers,
    selected: current,
    title: '选择小Q模型',
    // 已绑定时允许回到「跟随默认」，否则这项没有意义
    allowUnbind: current != null,
  );
  if (result == null || result.ref == current) return null;

  await AiRoleService.instance.bindRole('assistant', result.ref);
  ref.invalidate(aiRolesProvider);

  final name = result.ref != null
      ? aiModelDisplayName(result.ref, providers)
      : _fallbackModelName(providers);
  return (ref: result.ref, name: name);
}

String _fallbackModelName(List<AiProvider> providers) {
  final provider = providers.where((p) => p.isDefault && p.isUsable).firstOrNull ??
      providers.where((p) => p.isUsable).firstOrNull;
  final model = provider?.firstModel;
  return model == null ? '未配置模型' : model.name;
}