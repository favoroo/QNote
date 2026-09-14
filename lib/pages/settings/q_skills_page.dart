import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_usage_tracker.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
import 'package:qnote_flutter/pages/settings/q_skill_edit_page.dart';
import 'package:qnote_flutter/providers/agent_skill_provider.dart';

/// 小Q技能管理页
///
/// 仅展示用户技能，支持新增、编辑、删除与归档，与小Q经 VFS `/skills/*.md`
/// 的写入为同一份数据（app_configs 持久化），双向实时同步；
/// 技能使用统计（斜杠命令调用 + 小Q经 skill 工具加载）以徽标展示，
/// 辅助判断哪些技能值得保留、哪些可以归档（Curator 治理视角）；
/// 内置技能随 App 内置，不在管理页露出
class QSkillsPage extends ConsumerStatefulWidget {
  const QSkillsPage({super.key});

  @override
  ConsumerState<QSkillsPage> createState() => _QSkillsPageState();
}

class _QSkillsPageState extends ConsumerState<QSkillsPage> {
  Map<String, SkillUsageStat> _usageStats = {};

  @override
  void initState() {
    super.initState();
    _loadUsageStats();
  }

  Future<void> _loadUsageStats() async {
    final stats = await SkillUsageTracker.instance.getStats();
    if (mounted) setState(() => _usageStats = stats);
  }

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
          final userSkills = skills
              .where((s) => s['origin'] == AgentSkillOrigin.user)
              .toList();
          final activeSkills = userSkills
              .where((s) => s['archived'] != 'true')
              .toList();
          final archivedSkills = userSkills
              .where((s) => s['archived'] == 'true')
              .toList();

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _buildSectionCard(
                context,
                icon: Icons.auto_fix_high_outlined,
                title: '用户技能',
                count: activeSkills.length,
                emptyText: '暂无自定义技能，可点击右上角「+」新建',
                children: [
                  for (final skill in activeSkills) _buildSkillRow(context, skill),
                ],
              ),
              if (archivedSkills.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildSectionCard(
                  context,
                  icon: Icons.inventory_2_outlined,
                  title: '已归档',
                  count: archivedSkills.length,
                  children: [
                    for (final skill in archivedSkills)
                      _buildArchivedSkillRow(context, skill),
                  ],
                ),
              ],
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }

  /// 分区卡片：卡头（图标 + 标题 + 数量徽标）+ 内容列表，视觉对齐「小Q记忆」页
  Widget _buildSectionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required int count,
    required List<Widget> children,
    String? emptyText,
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
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '共 $count 个',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (children.isEmpty && emptyText != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                emptyText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...children,
        ],
      ),
    );
  }

  /// 使用次数徽标：从未使用时不显示，避免噪声
  Widget? _buildUsageBadge(BuildContext context, String name) {
    final stat = _usageStats[name];
    if (stat == null || stat.count <= 0) return null;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '用过 ${stat.count} 次',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  /// 活跃用户技能行：名称 + 描述 + 更新时间 + 使用徽标，点击进入编辑
  Widget _buildSkillRow(BuildContext context, Map<String, String> skill) {
    final theme = Theme.of(context);
    final name = skill['name']!;
    final description = skill['description'] ?? '';
    final userSkill = SkillRegistry.instance.getUserSkill(name);
    final updatedAt = userSkill?.updatedAt;
    final usageBadge = _buildUsageBadge(context, name);

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
          if (usageBadge != null) ...[
            const SizedBox(width: 6),
            usageBadge,
          ],
          if (updatedAt != null)
            Text(
              '更新于 ${DateFormat('MM-dd HH:mm').format(updatedAt)}',
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
      trailing: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_vert_rounded,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        tooltip: '更多操作',
        padding: EdgeInsets.zero,
        onSelected: (action) {
          if (action == 'archive') {
            _archiveSkill(name, true);
          } else if (action == 'delete') {
            _confirmDeleteSkill(name);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'archive',
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 18),
                SizedBox(width: 8),
                Text('归档'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 8),
                Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ],
      ),
      onTap: () => _openEditor(context, userSkill),
    );
  }

  /// 已归档技能行：淡化展示，提供恢复与删除入口
  Widget _buildArchivedSkillRow(BuildContext context, Map<String, String> skill) {
    final theme = Theme.of(context);
    final name = skill['name']!;
    final description = skill['description'] ?? '';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      dense: true,
      title: Text(
        name,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      subtitle: Text(
        '已归档，小Q不可见 · $description',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.restore_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            tooltip: '恢复',
            onPressed: () => _archiveSkill(name, false),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 20,
              color: theme.colorScheme.error,
            ),
            tooltip: '删除',
            onPressed: () => _confirmDeleteSkill(name),
          ),
        ],
      ),
      onTap: () => _archiveSkill(name, false),
    );
  }

  Future<void> _archiveSkill(String name, bool archived) async {
    try {
      await ref.read(agentSkillListProvider.notifier).archiveUserSkill(name, archived);
      await _loadUsageStats();
      if (!mounted) return;
      Toast.success(context, archived ? '已归档技能「$name」' : '已恢复技能「$name」');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, archived ? '归档失败：$e' : '恢复失败：$e');
    }
  }

  Future<void> _openEditor(BuildContext context, AgentSkill? skill) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QSkillEditPage(skill: skill),
      ),
    );
    // 返回后刷新一次，拾取编辑页可能的变更（事件总线通常已触发，这里兜底）
    if (mounted) {
      ref.invalidate(agentSkillListProvider);
      _loadUsageStats();
    }
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
      await _loadUsageStats();
      if (!mounted) return;
      Toast.success(context, '已删除技能「$name」');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '删除失败：$e');
    }
  }
}
