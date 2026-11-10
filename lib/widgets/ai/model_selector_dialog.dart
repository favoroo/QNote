import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/assistant_model_sheet.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';

export 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart'
    show
        aiBindingDisplayName,
        aiBindingShortName,
        aiModelDisplayName,
        defaultModelRef,
        enabledModelEntries;

/// 弹出小Q 对话模型选择面板（AI 主页面与悬浮小Q 面板共用入口）
///
/// 面板分两级：一级列路由组与厂商，二级列该厂商的模型并把「思考强度」一并调完
/// （参考 ZCode 的选择面板，思考强度跟着模型走）。点选即写库：绑定写
/// `AiRoles.assistant`，思考强度写回对应模型的 `reasoning_effort`。
/// 返回最终选中的绑定（ref + 展示名）；取消或未变更返回 null。
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
  if (effective == null) {
    await showNoModelConfiguredDialog(context, scene: '切换小Q模型');
    return null;
  }

  // 面板里点选即写库，这里只记录「有没有变过」用于返回值与提示
  var selected = effective;
  var changed = false;

  await showAssistantModelSheet(
    context,
    providers: providers,
    groups: groups,
    selected: effective,
    onSelectBinding: (next) async {
      if (next == selected) return true;
      try {
        // 先落库再让面板移动勾选：写失败时界面不能显示成已切换
        await AiRoleService.instance.bindRole('assistant', next);
        ref.invalidate(aiRolesProvider);
      } catch (e, st) {
        LoggerService.instance.error('切换小Q模型失败', details: '$e', stackTrace: st);
        if (context.mounted) Toast.error(context, '模型切换失败：$e');
        return false;
      }
      selected = next;
      changed = true;
      return true;
    },
    onEffortChanged: (targets, effort) async {
      try {
        await _writeEffort(ref, targets, effort);
      } catch (e, st) {
        LoggerService.instance.error('保存思考强度失败', details: '$e', stackTrace: st);
        if (context.mounted) Toast.error(context, '思考强度保存失败：$e');
        return false;
      }
      return true;
    },
    onManageModels: () =>
        rootNavigatorKey.currentContext?.push('/settings/ai-config'),
  );

  if (!changed) return null;
  return (
    ref: selected,
    name: aiBindingDisplayName(selected, providers, groups),
  );
}

/// 把思考强度写回目标模型：按厂商条目聚合，一个条目只更新一次
///
/// 路由组的成员可能横跨多个厂商条目，逐条目写回才不会互相覆盖。
Future<void> _writeEffort(
  WidgetRef ref,
  List<ReasoningEffortTarget> targets,
  ReasoningEffort? effort,
) async {
  final byProvider = <String, List<ReasoningEffortTarget>>{};
  for (final target in targets) {
    byProvider.putIfAbsent(target.provider.id, () => []).add(target);
  }

  final notifier = ref.read(aiProviderListProvider.notifier);
  for (final group in byProvider.values) {
    final provider = group.first.provider;
    final ids = group.map((t) => t.model.id).toSet();
    final updatedModels = provider.models
        .map(
          (m) => ids.contains(m.id) ? m.copyWith(reasoningEffort: effort) : m,
        )
        .toList();
    await notifier.updateProvider(provider.copyWith(models: updatedModels));
  }
}
