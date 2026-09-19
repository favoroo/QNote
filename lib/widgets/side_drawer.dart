import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/pages/settings/user_profile_page.dart';
import 'package:qnote_flutter/pages/settings/q_settings_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/shortcuts_page.dart';
import 'package:qnote_flutter/pages/settings/fixed_events_page.dart';
import 'package:qnote_flutter/pages/settings/data_sync_page.dart';
import 'package:qnote_flutter/pages/settings/mi_fitness_settings_page.dart';
import 'package:qnote_flutter/pages/settings/screen_usage_page.dart';
import 'package:qnote_flutter/pages/settings/about_page.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';

class SideDrawer extends ConsumerStatefulWidget {
  const SideDrawer({super.key});

  @override
  ConsumerState<SideDrawer> createState() => _SideDrawerState();
}

class _SideDrawerState extends ConsumerState<SideDrawer> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Drawer(
      width: 360, // Slightly wider sidebar for better display of nested pages
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: ScaffoldMessenger(
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(24),
            bottomRight: Radius.circular(24),
          ),
          child: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) return;
              if (_navigatorKey.currentState?.canPop() ?? false) {
                _navigatorKey.currentState?.pop();
              } else {
                Navigator.of(context).pop();
              }
            },
            child: Navigator(
              key: _navigatorKey,
              onGenerateRoute: (settings) {
                WidgetBuilder builder;
                if (settings.name == '/') {
                  builder = (context) => _buildMenu(context);
                } else {
                  builder = (context) => settings.arguments as Widget;
                }
                return MaterialPageRoute(builder: builder, settings: settings);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'QNote',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  // 全部入口收进一张集合卡片：扁平无分组，行间以超细分隔线区隔
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(AppRadius.large),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < _menuEntries.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 0.5,
                              indent: 60,
                              endIndent: 16,
                              color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.5),
                            ),
                          _DrawerMenuItem(
                            entry: _menuEntries[i],
                            onTap: () => _navigateTo(context, _menuEntries[i].page),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom theme toggle or version
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Row(
                children: [
                  Text(
                    'Version ${AppVersion.version}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _navigateTo(BuildContext context, Widget page) {
    _navigatorKey.currentState!.pushNamed('/page', arguments: page);
  }
}

/// 抽屉菜单项描述：icon 与 iconWidget 二选一
class _MenuEntry {
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final Widget page;

  const _MenuEntry({this.icon, this.iconWidget, required this.label, required this.page});
}

/// 抽屉入口清单：扁平一屏陈列，统一品牌色，不再按「设置/其他」分组
const List<_MenuEntry> _menuEntries = [
  _MenuEntry(icon: Icons.person_outline, label: '个人信息', page: UserProfilePage()),
  _MenuEntry(
    iconWidget: QAvatar(size: 32, withBackground: true),
    label: '小Q设置',
    page: QSettingsPage(),
  ),
  _MenuEntry(icon: Icons.tune_rounded, label: 'AI 配置', page: AiConfigPage()),
  _MenuEntry(icon: Icons.hexagon_outlined, label: '快捷按钮管理', page: ShortcutsPage()),
  _MenuEntry(icon: Icons.event_repeat, label: '固定事件管理', page: FixedEventsPage()),
  _MenuEntry(icon: Icons.sync_rounded, label: '数据与同步', page: DataSyncPage()),
  _MenuEntry(icon: Icons.favorite_border_rounded, label: '小米运动健康', page: MiFitnessSettingsPage()),
  _MenuEntry(icon: Icons.hourglass_bottom_rounded, label: '屏幕使用时间', page: ScreenUsagePage()),
  _MenuEntry(icon: Icons.palette_outlined, label: '个性化设置', page: PersonalizationPage()),
  _MenuEntry(icon: Icons.info_outline, label: '关于 QNote', page: AboutPage()),
];

class _DrawerMenuItem extends StatelessWidget {
  final _MenuEntry entry;
  final VoidCallback onTap;

  const _DrawerMenuItem({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 统一品牌色小圆底，压低图标色彩权重，让列表主体保持干净
    final Widget leading = entry.iconWidget ??
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(entry.icon, color: colorScheme.primary, size: 17),
        );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      horizontalTitleGap: 12,
      minLeadingWidth: 0,
      visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      leading: leading,
      title: Text(
        entry.label,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
      ),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.medium)),
    );
  }
}
