import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
import 'package:qnote_flutter/pages/settings/q_skill_edit_page.dart';
import 'package:qnote_flutter/providers/agent_skill_provider.dart';

/// 小Q技能管理页
///
/// 内置技能只读可查阅；用户技能支持新增、编辑与删除，与小Q经 VFS
/// `/skills/*.md` 的写入为同一份数据（app_configs 持久化），双向实时同步
class QSkillsPage extends ConsumerStatefulWidget {
  const QSkillsPage({super.key});

  @override
  ConsumerState<QSkillsPage> createState() => _QSkillsPageState();
}

class _QSkillsPageState extends ConsumerState<QSkillsPage> {
  @override
  Widget build(BuildContext context) {
    final skillsAsync = ref.watch(agentSkillListProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('小Q技能'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建技能',
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: skillsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $e', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => ref.invalidate(agentSkillListProvider),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (skills) {
          final builtinSkills =
              skills.where((s) => s['origin'] == AgentSkillOrigin.builtin).toList();
          final userSkills =
              skills.where((s) => s['origin'] == AgentSkillOrigin.user).toList();
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _buildSectionCard(
                context,
                title: '内置技能',
                subtitle: '随 App 版本更新，不可修改',
                icon: Icons.verified_outlined,
                children: [
                  for (final skill in builtinSkills)
                    _buildSkillRow(context, skill, isBuiltin: true),
                ],
              ),
              const SizedBox(height: 20),
              _buildSectionCard(
                context,
                title: '用户技能',
                subtitle: '你的自定义手册，可与小Q共同维护，App 更新不会覆盖',
                icon: Icons.auto_fix_high_outlined,
                children: [
                  if (userSkills.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '还没有自定义技能。点击右上角「+」新建，或直接对小Q说'
                        '「帮我把这套流程做成技能」，它会写入 /skills/ 下的技能手册。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    for (final skill in userSkills)
                      _buildSkillRow(context, skill, isBuiltin: false),
                ],
              ),
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }

  /// 分区卡片：卡头（图标 + 标题 + 副标题）+ 技能行列表，视觉对齐「小Q记忆」页
  Widget _buildSectionCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  /// 单个技能行：名称 + 描述，点击进入详情/编辑；用户技能附删除入口
  Widget _buildSkillRow(BuildContext context, Map<String, String> skill, {required bool isBuiltin}) {
    final theme = Theme.of(context);
    final name = skill['name']!;
    final description = skill['description'] ?? '';
    final userSkill = isBuiltin ? null : SkillRegistry.instance.getUserSkill(name);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      dense: true,
      title: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (userSkill != null)
            Text(
              '更新于 ${DateFormat('MM-dd HH:mm').format(userSkill.updatedAt)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      subtitle: Text(
        description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: isBuiltin
          ? Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.onSurfaceVariant)
          : IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: theme.colorScheme.error,
              tooltip: '删除',
              onPressed: () => _confirmDeleteSkill(name),
            ),
      onTap: () => _openEditor(context, isBuiltin ? null : userSkill, builtinName: isBuiltin ? name : null),
    );
  }

  Future<void> _openEditor(BuildContext context, AgentSkill? skill, {String? builtinName}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QSkillEditPage(skill: skill, builtinName: builtinName),
      ),
    );
    // 返回后刷新一次，拾取编辑页可能的变更（事件总线通常已触发，这里兜底）
    if (mounted) ref.invalidate(agentSkillListProvider);
  }

  Future<void> _confirmDeleteSkill(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除技能'),
        content: Text('确定删除技能「$name」吗？删除后小Q将无法再查阅这份手册。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(agentSkillListProvider.notifier).deleteUserSkill(name);
      if (!mounted) return;
      Toast.success(context, '已删除技能「$name」');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '删除失败：$e');
    }
  }
}
