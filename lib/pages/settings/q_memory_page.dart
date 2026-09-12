import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/agent_memory.dart';
import 'package:qnote_flutter/providers/agent_memory_provider.dart';

/// 小Q长期记忆管理页
///
/// 展示并编辑小Q在对话中自主沉淀的长期记忆（用户画像 / 小Q手记），
/// 与 Agent 侧的 `/memory/*.md` 虚拟文件为同一份数据，双向实时同步
class QMemoryPage extends ConsumerStatefulWidget {
  const QMemoryPage({super.key});

  @override
  ConsumerState<QMemoryPage> createState() => _QMemoryPageState();
}

class _QMemoryPageState extends ConsumerState<QMemoryPage> {
  @override
  Widget build(BuildContext context) {
    final memoriesAsync = ref.watch(agentMemoryListProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('小Q记忆'),
        centerTitle: false,
      ),
      body: memoriesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败: $e', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => ref.invalidate(agentMemoryListProvider),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (docs) {
          if (docs.every((d) => d.entries.isEmpty)) {
            return _buildEmptyState(theme);
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (int i = 0; i < docs.length; i++) ...[
                if (i > 0) const SizedBox(height: 20),
                _buildMemoryCard(context, docs[i]),
              ],
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }

  /// 全空态：介绍记忆机制，引导用户与小Q对话沉淀记忆
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined,
                size: 56, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('还没有任何记忆', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '和小Q聊天时，它会自动把你的偏好、习惯与重要约定沉淀到这里；'
              '你也可以手动添加，每次对话都会自动载入小Q的上下文。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => _showEntryDialog(category: AgentMemoryCategory.user),
              icon: const Icon(Icons.add),
              label: const Text('手动添加一条'),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个记忆分区卡片：卡头（标题 + 容量）+ 条目列表 + 添加入口
  Widget _buildMemoryCard(BuildContext context, AgentMemoryDocument doc) {
    final theme = Theme.of(context);
    final maxChars = AgentMemoryCategory.maxChars(doc.category);
    final isOver = doc.usagePercent >= 80;

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
              Icon(
                doc.category == AgentMemoryCategory.user
                    ? Icons.face_retouching_natural_outlined
                    : Icons.auto_awesome_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AgentMemoryCategory.displayName(doc.category),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              // 容量徽标：接近上限时转为警示色，提示需要整合
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isOver
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${doc.usagePercent}% · ${doc.content.length}/$maxChars',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isOver
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (doc.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无记忆条目，小Q会在对话中自动沉淀，也可以点击下方按钮手动添加。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...doc.entries.map(
              (entry) => _buildEntryRow(context, doc.category, entry),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _showEntryDialog(category: doc.category),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加条目'),
            ),
          ),
        ],
      ),
    );
  }

  /// 单条记忆行：内容 + 编辑/删除操作
  Widget _buildEntryRow(BuildContext context, String category, String entry) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Icon(Icons.circle, size: 6, color: theme.colorScheme.primary.withValues(alpha: 0.6)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(entry, style: theme.textTheme.bodyMedium),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 20),
            color: theme.colorScheme.onSurfaceVariant,
            tooltip: '编辑',
            onPressed: () => _showEntryDialog(
              category: category,
              initialText: entry,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: theme.colorScheme.error,
            tooltip: '删除',
            onPressed: () => _confirmDeleteEntry(category, entry),
          ),
        ],
      ),
    );
  }

  /// 新增/编辑一条记忆的弹窗；编辑时按原文本精准替换
  Future<void> _showEntryDialog({
    required String category,
    String? initialText,
  }) async {
    final controller = TextEditingController(text: initialText ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(initialText == null ? '添加记忆' : '编辑记忆'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          maxLength: AgentMemoryCategory.maxChars(category),
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: '例如：习惯晚上 11 点后不安排提醒',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return;

    if (text.isEmpty) {
      if (!mounted) return;
      Toast.warning(context, '记忆内容不能为空');
      return;
    }

    try {
      final notifier = ref.read(agentMemoryListProvider.notifier);
      if (initialText == null) {
        await notifier.addEntry(category, text);
      } else {
        await notifier.updateEntry(category, initialText, text);
      }
      if (!mounted) return;
      Toast.success(context, initialText == null ? '已添加记忆' : '已更新记忆');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  /// 删除单条记忆（破坏性操作，二次确认）
  Future<void> _confirmDeleteEntry(String category, String entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除记忆'),
        content: const Text('确定删除这条记忆吗？删除后小Q将不再记得该内容。'),
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
      await ref.read(agentMemoryListProvider.notifier).deleteEntry(category, entry);
      if (!mounted) return;
      Toast.success(context, '已删除');
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '删除失败：$e');
    }
  }
}
