import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/pages/settings/user_profile_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/shortcuts_page.dart';
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
                    iconBgColor: Colors.blue.withValues(alpha: 0.1),
                    iconColor: Colors.blue,
                    label: '个人信息',
                    onTap: () => _navigateTo(context, const UserProfilePage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.smart_toy_outlined,
                    iconBgColor: Colors.deepPurple.withValues(alpha: 0.1),
                    iconColor: Colors.deepPurple,
                    label: 'AI 配置',
                    onTap: () => _navigateTo(context, const AiConfigPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.hexagon_outlined,
                    iconBgColor: Colors.orange.withValues(alpha: 0.1),
                    iconColor: Colors.orange,
                    label: '快捷按钮管理',
                    onTap: () => _navigateTo(context, const ShortcutsPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.cloud_outlined,
                    iconBgColor: Colors.indigo.withValues(alpha: 0.1),
                    iconColor: Colors.indigo,
                    label: '数据管理',
                    onTap: () => _navigateTo(context, const DataManagementPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.sync_rounded,
                    iconBgColor: Colors.lightBlue.withValues(alpha: 0.1),
                    iconColor: Colors.lightBlue,
                    label: '同步设置',
                    onTap: () => _navigateTo(context, const SyncSettingsPage()),
                  ),
                  _DrawerMenuItem(
                    icon: Icons.palette_outlined,
                    iconBgColor: Colors.red.withValues(alpha: 0.1),
                    iconColor: Colors.red,
                    label: '个性化设置',
                    onTap: () => _navigateTo(context, const PersonalizationPage()),
                  ),
                  const SizedBox(height: 24),
                  const Divider(indent: 8, endIndent: 8),
                  const SizedBox(height: 16),
                  _SectionHeader(title: '其他'),
                  _DrawerMenuItem(
                    icon: Icons.info_outline,
                    iconBgColor: Colors.blueGrey.withValues(alpha: 0.1),
                    iconColor: Colors.blueGrey,
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
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
