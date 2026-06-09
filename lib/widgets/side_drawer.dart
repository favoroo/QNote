import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/pages/settings/user_profile_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/shortcuts_page.dart';
import 'package:qnote_flutter/pages/settings/fixed_events_page.dart';
import 'package:qnote_flutter/pages/settings/data_management_page.dart';
import 'package:qnote_flutter/pages/settings/sync_settings_page.dart';
import 'package:qnote_flutter/pages/settings/about_page.dart';

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

    // 个人信息：使用系统主品牌色（蓝色），代表身份与主要入口
    final profileColor = colorScheme.primary;
    final profileBgColor = colorScheme.primaryContainer;

    // AI 配置：使用紫罗兰色（Purple），富有机能感与智慧感
    final aiColor = isDark ? const Color(0xFFB39DDB) : const Color(0xFF673AB7);
    final aiBgColor = aiColor.withValues(alpha: isDark ? 0.18 : 0.1);

    // 快捷按钮：使用琥珀橙色（Orange），代表高效、操作与自定义工具
    final shortcutColor = isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100);
    final shortcutBgColor = shortcutColor.withValues(alpha: isDark ? 0.18 : 0.1);

    // 数据管理：使用翡翠青色（Teal），代表冷静、稳固与存储安全
    final dataColor = isDark ? const Color(0xFF4DB6AC) : const Color(0xFF00796B);
    final dataBgColor = dataColor.withValues(alpha: isDark ? 0.18 : 0.1);

    // 同步设置：使用薄荷绿色（Green），代表畅通、健康的数据传输
    final syncColor = isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
    final syncBgColor = syncColor.withValues(alpha: isDark ? 0.18 : 0.1);

    // 个性化设置：使用玫瑰粉色（Pink），代表丰富色彩与界面美化，比原先的 error 红色更温和且契合主题
    final personalizationColor = isDark ? const Color(0xFFF48FB1) : const Color(0xFFD81B60);
    final personalizationBgColor = personalizationColor.withValues(alpha: isDark ? 0.18 : 0.1);

    // 关于 QNote：使用中性灰色，低调不喧宾夺主
    final aboutColor = colorScheme.onSurfaceVariant;
    final aboutBgColor = aboutColor.withValues(alpha: isDark ? 0.15 : 0.08);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _SectionHeader(title: '设置与管理'),
                  _DrawerMenuItem(
                    icon: Icons.person_outline,
                    iconBgColor: profileBgColor,
                    iconColor: profileColor,
                    label: '个人信息',
                    onTap: () => _navigateTo(context, const UserProfilePage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.smart_toy_outlined,
                    iconBgColor: aiBgColor,
                    iconColor: aiColor,
                    label: 'AI 配置',
                    onTap: () => _navigateTo(context, const AiConfigPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.hexagon_outlined,
                    iconBgColor: shortcutBgColor,
                    iconColor: shortcutColor,
                    label: '快捷按钮管理',
                    onTap: () => _navigateTo(context, const ShortcutsPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.event_repeat,
                    iconBgColor: shortcutBgColor,
                    iconColor: shortcutColor,
                    label: '固定事件管理',
                    onTap: () => _navigateTo(context, const FixedEventsPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.cloud_outlined,
                    iconBgColor: dataBgColor,
                    iconColor: dataColor,
                    label: '数据管理',
                    onTap: () => _navigateTo(context, const DataManagementPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.sync_rounded,
                    iconBgColor: syncBgColor,
                    iconColor: syncColor,
                    label: '同步设置',
                    onTap: () => _navigateTo(context, const SyncSettingsPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.palette_outlined,
                    iconBgColor: personalizationBgColor,
                    iconColor: personalizationColor,
                    label: '个性化设置',
                    onTap: () => _navigateTo(context, const PersonalizationPage()),
                  ),
                  const SizedBox(height: 24),
                  const Divider(indent: 8, endIndent: 8),
                  const SizedBox(height: 16),
                  _SectionHeader(title: '其他'),
                  _DrawerMenuItem(
                    icon: Icons.info_outline,
                    iconBgColor: aboutBgColor,
                    iconColor: aboutColor,
                    label: '关于 QNote',
                    onTap: () => _navigateTo(context, const AboutPage()),
                  ),
                ],
              ),
            ),

            // Bottom theme toggle or version
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Row(
                children: [
                  Text(
                    'Version 1.2.0',
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

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

class _DrawerMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconBgColor;
  final Color iconColor;
  final VoidCallback onTap;

  const _DrawerMenuItem({
    required this.icon,
    required this.label,
    required this.iconBgColor,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0), // Reduced spacing between items
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: iconBgColor,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: iconColor, size: 22),
        ),
        title: Text(
          label,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
        ),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.medium)),
      ),
    );
  }
}
