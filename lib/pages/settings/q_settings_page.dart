import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/pages/settings/q_memory_page.dart';
import 'package:qnote_flutter/pages/settings/q_personality_page.dart';
import 'package:qnote_flutter/pages/settings/q_skills_page.dart';

/// 小Q设置（管理）一体化页面
///
/// 将原侧边栏分散的「小Q个性」、「小Q技能」与「小Q记忆」三个板块
/// 整合为统一入口，提供顶部平滑切换分段栏：
/// - 个性：人设、语气风格与自定义 Prompt；
/// - 技能：用户技能、使用次数统计、创建/编辑/归档；
/// - 记忆：长期记忆（用户画像与小Q手记）、条目编辑与沉淀管理。
class QSettingsPage extends ConsumerStatefulWidget {
  const QSettingsPage({super.key, this.initialTab = 0});

  /// 初始分区索引：0 个性 / 1 技能 / 2 记忆
  final int initialTab;

  @override
  ConsumerState<QSettingsPage> createState() => _QSettingsPageState();
}

class _QSettingsPageState extends ConsumerState<QSettingsPage> {
  static const _tabs = <_TabItem>[
    _TabItem(title: '个性', icon: Icons.mood_outlined),
    _TabItem(title: '技能', icon: Icons.auto_fix_high_outlined),
    _TabItem(title: '记忆', icon: Icons.psychology_outlined),
  ];

  late int _currentIndex;
  final GlobalKey<QSkillsPageState> _skillsKey = GlobalKey<QSkillsPageState>();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab.clamp(0, _tabs.length - 1);
  }

  void _switchTo(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('小Q设置'),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          // 仅在「技能」分区时显示右上角新建技能按钮
          if (_currentIndex == 1)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新建技能',
              onPressed: () => _skillsKey.currentState?.openNewSkillEditor(),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildTabSelector(context),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                const QPersonalityPage(embedded: true),
                QSkillsPage(key: _skillsKey, embedded: true),
                const QMemoryPage(embedded: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分段式分区切换器
  Widget _buildTabSelector(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: List.generate(_tabs.length, (index) {
          final selected = index == _currentIndex;
          final tab = _tabs[index];
          return Expanded(
            child: InkWell(
              onTap: () => _switchTo(index),
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: selected ? colorScheme.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tab.icon,
                      size: 16,
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      tab.title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                        color: selected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _TabItem {
  final String title;
  final IconData icon;

  const _TabItem({required this.title, required this.icon});
}
