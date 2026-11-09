import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

export 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart'
    show aiBindingDisplayName, aiModelDisplayName, defaultModelRef, enabledModelEntries;

/// 弹出小Q 对话模型选择弹层（AI 主页面与悬浮小Q 面板共用入口）
///
/// 选中且与当前不同时写入全局 `AiRoles.assistant` 角色绑定并刷新
/// [aiRolesProvider]，返回选中项（ref + 展示名）；取消或未变更返回 null。
/// 两处界面共用同一角色设置，任一处切换即全局生效。可选项里同时包含具体模型与
/// 模型路由组（组以组名展示，绑定后由 `AiRouteService` 按策略选成员）。
///
/// 一个已启用模型与路由组都没有时不做选择器，直接弹「去添加模型」引导。
Future<({AiModelRef ref, String name})?> showAssistantModelSelector(
  BuildContext context,
  WidgetRef ref,
) async {
  final providers = await ref.read(aiProviderListProvider.future);
  final groups = await ref.read(aiRouteGroupListProvider.future);
  if (!context.mounted) return null;

  if (enabledModelEntries(providers).isEmpty && groups.isEmpty) {
    await showNoModelConfiguredDialog(context, scene: '切换小Q模型');
    return null;
  }

  final roles = await ref.read(aiRolesProvider.future);
  if (!context.mounted) return null;
  final current = roles?.assistant;
  final effective = isBindingUsable(current, providers, groups)
      ? current
      : defaultModelRef(providers);

  final result = await showModelPickerSheet(
    context,
    providers: providers,
    groups: groups,
    selected: effective,
    title: '选择小Q模型',
  );
  if (result == null || result.ref == current) return null;

  await AiRoleService.instance.bindRole('assistant', result.ref);
  ref.invalidate(aiRolesProvider);

  final name = aiBindingDisplayName(result.ref, providers, groups);
  return (ref: result.ref, name: name);
}
