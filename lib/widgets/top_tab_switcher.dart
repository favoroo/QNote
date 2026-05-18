import 'package:flutter/material.dart';

class TopTabSwitcher extends StatelessWidget {
  final String activeTab;
  final ValueChanged<String> onTabSelected;

  const TopTabSwitcher({
    super.key,
    required this.activeTab,
    required this.onTabSelected,
  });

  static Future<void> show(
    BuildContext context, {
    required String activeTab,
    required ValueChanged<String> onTabSelected,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'TabSwitcher',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return TopTabSwitcher(
          activeTab: activeTab,
          onTabSelected: (tab) {
            Navigator.of(context).pop();
            onTabSelected(tab);
          },
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '快速切换',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                      iconSize: 20,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _tabItems.map((item) {
                    final isActive = item.tabType == activeTab;
                    return _TabItem(
                      item: item,
                      isActive: isActive,
                      theme: theme,
                      onTap: () => onTabSelected(item.tabType),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final _TabConfig item;
  final bool isActive;
  final ThemeData theme;
  final VoidCallback onTap;

  const _TabItem({
    required this.item,
    required this.isActive,
    required this.theme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: (MediaQuery.of(context).size.width - 96) / 3,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item.icon,
                color: isActive
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                size: 24,
              ),
              const SizedBox(height: 6),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: isActive
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabConfig {
  final IconData icon;
  final String label;
  final String tabType;

  const _TabConfig({
    required this.icon,
    required this.label,
    required this.tabType,
  });
}

const _tabItems = [
  _TabConfig(icon: Icons.book, label: '时间轴', tabType: 'diary'),
  _TabConfig(icon: Icons.note, label: '笔记', tabType: 'notes'),
  _TabConfig(icon: Icons.check_circle, label: '任务', tabType: 'todo'),
  _TabConfig(icon: Icons.smart_toy, label: 'AI助手', tabType: 'ai'),
  _TabConfig(icon: Icons.bar_chart, label: '数据统计', tabType: 'statistics'),
];
