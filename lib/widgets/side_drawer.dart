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

/// 侧边栏（抽屉）。
///
/// 间距按 6 / 14 / 16 / 24 四档刻度收口：6 用于卡片内边距与分隔线留白，
/// 14 用于行内横向缩进与图标到文字的间距，16 用于卡片外边距，24 用于头部与
/// 底部区域的左右基线。行高交给 ListTile 的默认 [VisualDensity.standard]
/// （约 56），不再用负 density 压缩，避免整列贴边、难以扫读。
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
              padding: const EdgeInsets.fromLTRB(24, 20, 14, 14),
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
                padding: const EdgeInsets.only(top: 4, bottom: 16),
                children: [
                  // 全部入口收进一张集合卡片：扁平无分组，行间以超细分隔线区隔。
                  // 卡片只描边、不填色——抽屉底色已是 surface，再铺一层不透明
                  // 填充会把 InkWell 的悬停/按下高亮盖住（Ink 特征画在 Material 层，
                  // 本容器是其后代、绘制在其之上），因此这里必须保持透明。
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.large),
                      border: Border.all(
                        width: 1,
                        // 浅色下 outlineVariant 本身已很淡，需满 alpha 才能撑住卡片边界；
                        // 深色底对比更强，压到 0.6 避免描边发亮
                        color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.6 : 1.0),
                      ),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < _menuEntries.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 9,
                              thickness: 0.5,
                              // indent = 卡片内边距 6 + 行内缩进 14 + 图标 36 + 文字间距 14，
                              // 使分隔线左端与菜单文字左缘对齐（此处按内容盒计算为 64）
                              indent: 64,
                              endIndent: 8,
                              color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.45 : 0.9),
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
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
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
    iconWidget: QAvatar(size: 36, withBackground: true),
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
    final isDark = theme.brightness == Brightness.dark;

    // 统一品牌色小圆底，压低图标色彩权重，让列表主体保持干净
    final Widget leading = entry.iconWidget ??
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(entry.icon, color: colorScheme.primary, size: 19),
        );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      horizontalTitleGap: 14,
      minLeadingWidth: 0,
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
        size: 20,
        // 0.25 时箭头几乎看不见，提到 0.4 让「可进入」的暗示清晰且不过重
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
      ),
      // Web/桌面端悬停与键盘聚焦反馈；ListTileThemeData 不提供 hoverColor，
      // 因此只能在 widget 上局部设置（浅色底用更低 alpha 保持克制）。
      // 按下态用 splashColor（ListTile 没有 highlightColor 参数）。
      hoverColor: colorScheme.primary.withValues(alpha: isDark ? 0.10 : 0.06),
      focusColor: colorScheme.primary.withValues(alpha: isDark ? 0.14 : 0.10),
      splashColor: colorScheme.primary.withValues(alpha: isDark ? 0.16 : 0.12),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.medium)),
    );
  }
}
