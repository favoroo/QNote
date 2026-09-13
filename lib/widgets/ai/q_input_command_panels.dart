import 'package:flutter/material.dart';

/// 斜杠命令面板：输入 `/` 触发的技能候选浮层
///
/// 展示技能名、一句话描述与使用次数徽标；点击后由父级将命令词
/// 替换进输入框。数据由父级过滤后传入，面板自身不做过滤。
class SlashCommandPanel extends StatelessWidget {
  /// 候选技能列表（Map 需含 name / description，可选 usageCount）
  final List<Map<String, String?>> skills;

  /// 当前命令词（用于空态文案与高亮）
  final String query;

  /// 选中某个技能（参数为技能名）
  final ValueChanged<String> onSelected;

  const SlashCommandPanel({
    super.key,
    required this.skills,
    required this.query,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      constraints: const BoxConstraints(maxHeight: 232),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: Row(
              children: [
                Icon(
                  Icons.bolt_rounded,
                  size: 14,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  '斜杠命令',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '输入 / 调用技能，选中后手册自动注入',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: skills.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    child: Text(
                      query.isEmpty
                          ? '暂无可用技能'
                          : '没有匹配「$query」的技能，发送后将按普通消息处理',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 6),
                    itemCount: skills.length,
                    itemBuilder: (context, index) {
                      final skill = skills[index];
                      final name = skill['name'] ?? '';
                      final usageCount =
                          int.tryParse(skill['usageCount'] ?? '') ?? 0;
                      return InkWell(
                        onTap: () => onSelected(name),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Text(
                                '/$name',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (usageCount > 0) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.secondaryContainer
                                        .withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '用过 $usageCount 次',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSecondaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  skill['description'] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
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

/// @ 引用类别
enum AtReferenceKind {
  note(Icons.description_outlined, '引用笔记'),
  todo(Icons.check_box_outlined, '引用待办'),
  journal(Icons.auto_stories_outlined, '引用日记');

  const AtReferenceKind(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// @ 引用面板：输入 `@` 触发的内容引用浮层
///
/// 提供笔记 / 待办 / 日历日记三个入口，选中后由父级移除 `@` 命令词
/// 并打开对应的多选弹窗，引用结果走既有附件挂载条展示。
class AtReferencePanel extends StatelessWidget {
  /// 选择某个引用类别（笔记/待办/日记）
  final ValueChanged<AtReferenceKind> onSelected;

  const AtReferencePanel({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: Text(
              '引用内容给小Q',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final kind in AtReferenceKind.values)
            InkWell(
              onTap: () => onSelected(kind),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      kind.icon,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        kind.label,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
