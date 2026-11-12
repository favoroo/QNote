import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/pages/settings/user_profile_page.dart';
import 'package:qnote_flutter/pages/settings/q_settings_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/quick_record_settings_page.dart';
import 'package:qnote_flutter/pages/settings/health_settings_page.dart';
import 'package:qnote_flutter/pages/settings/data_sync_page.dart';
import 'package:qnote_flutter/pages/settings/about_page.dart';
import 'package:qnote_flutter/providers/drawer_nav_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';

/// 侧边栏（抽屉）。
///
/// 间距按 6 / 14 / 16 / 24 四档刻度收口：6 用于卡片内边距与分隔线留白，
/// 14 用于行内横向缩进与图标到文字的间距，16 用于卡片外边距，24 用于头部与
/// 底部区域的左右基线。行高交给 ListTile 的默认 [VisualDensity.standard]
/// （约 56），不再用负 density 压缩，避免整列贴边、难以扫读。
///
/// 抽屉一关，[DrawerController] 就会卸载整棵子树（内嵌 Navigator 连同页面栈一起
/// 消失），所以「上次停在哪」由 [DrawerNavMemory] 记在抽屉之外：关闭时写入，
/// 在 [kDrawerResumeWindow] 内重新打开则把页面栈直接重建回该入口，超过窗口视作
/// 一次新的「找设置」动作，回到一级菜单。
class SideDrawer extends ConsumerStatefulWidget {
  const SideDrawer({super.key});

  @override
  ConsumerState<SideDrawer> createState() => _SideDrawerState();
}

class _SideDrawerState extends ConsumerState<SideDrawer> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 抽屉关闭即整棵子树被卸载，`dispose` 里 context 已失效不能再走 `ref`，
  /// 因此 initState 先抓住记忆对象留到关闭时写回。
  late final DrawerNavMemory _navMemory;

  /// 本次打开抽屉时还原到的入口；null 表示从一级菜单开始
  _MenuEntry? _resumeEntry;

  /// 当前停留的入口 id（在入口页内再压的深层页面仍归属该入口）
  String? _currentEntryId;

  late final NavigatorObserver _routeTracker;

  @override
  void initState() {
    super.initState();
    _navMemory = ref.read(drawerNavMemoryProvider);
    // 过期判断只在此刻做一次：之后抽屉内的导航都是用户当下的真实位置
    final resumeId = _navMemory.resumableEntryId();
    _resumeEntry = resumeId == null ? null : _entryById(resumeId);
    _currentEntryId = _resumeEntry?.id;
    _routeTracker = _DrawerEntryTracker((entryId) => _currentEntryId = entryId);
  }

  @override
  void dispose() {
    // 关闭抽屉时记下位置，供 kDrawerResumeWindow 内重新打开时还原
    _navMemory.recordClosed(entryId: _currentEntryId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Drawer(
      width: 360, // Slightly wider sidebar for better display of nested pages
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topRight: Radius.circular(24), bottomRight: Radius.circular(24)),
      ),
      child: ScaffoldMessenger(
        child: ClipRRect(
          borderRadius: const BorderRadius.only(topRight: Radius.circular(24), bottomRight: Radius.circular(24)),
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
              observers: [_routeTracker],
              // 抽屉每次打开都是全新子树，初始栈只能在这里生成：
              // 一级菜单 +（可选）上次停留的入口
              onGenerateInitialRoutes: (navigator, initialRoute) {
                return [_menuRoute(), if (_resumeEntry != null) _entryRoute(_resumeEntry!)];
              },
              onGenerateRoute: (settings) {
                if (settings.name == _menuRouteName) return _menuRoute();
                final id = settings.name!.substring(_entryRoutePrefix.length);
                final entry = _entryById(id);
                // 入口清单已变（版本升级删过条目）时退回菜单，不把用户丢在空路由上
                return entry == null ? _menuRoute() : _entryRoute(entry);
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

    // 抽屉首开时整棵子树与动画首帧同帧构建（DrawerController 关闭态不挂载内容），
    // 这里用轻量 Material 代替内嵌 Scaffold 减小每次打开的构建与布局成本；
    // ink 高亮仍画在外层 Drawer 自带的 Material 上，Toast 由外层 ScaffoldMessenger 负责
    return Material(
      color: Colors.transparent,
      child: SafeArea(
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
                  // 数据统计是主功能而非设置项：单独一张卡片置顶，
                  // 与下面的设置列表分层，避免被当成又一个设置入口
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.large),
                      border: Border.all(
                        width: 1,
                        color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.6 : 1.0),
                      ),
                    ),
                    child: _DrawerMenuItem(
                      entry: _statisticsEntry,
                      onTap: () => _navigateTo(context, _statisticsEntry),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 设置类入口收进一张集合卡片：扁平无分组，行间以超细分隔线区隔。
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
                          _DrawerMenuItem(entry: _menuEntries[i], onTap: () => _navigateTo(context, _menuEntries[i])),
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

  void _navigateTo(BuildContext context, _MenuEntry entry) {
    // 统计这类整页图表不塞进 360 宽的抽屉内嵌 Navigator：
    // 先收起抽屉，再以根路由全屏打开
    final route = entry.route;
    if (route != null) {
      _openFullScreen(context, route);
      return;
    }
    _navigatorKey.currentState!.pushNamed('$_entryRoutePrefix${entry.id}');
  }

  /// 收起抽屉后用根路由全屏打开二级页面。
  ///
  /// 先取到 router 再关闭抽屉：关闭动画会卸载抽屉子树，晚取 context 已失效。
  void _openFullScreen(BuildContext context, String route) {
    final router = GoRouter.of(context);
    rootScaffoldKey.currentState?.closeDrawer();
    router.push(route);
  }

  Route<void> _menuRoute() {
    return MaterialPageRoute<void>(
      settings: const RouteSettings(name: _menuRouteName),
      builder: (context) => _buildMenu(context),
    );
  }

  Route<void> _entryRoute(_MenuEntry entry) {
    return MaterialPageRoute<void>(
      settings: RouteSettings(name: '$_entryRoutePrefix${entry.id}'),
      // 带 route 的入口走根路由全屏打开，不会进入这里
      builder: (context) => entry.page!,
    );
  }
}

/// 内嵌导航的路由命名：一级菜单固定 `/`，各入口为 `/entry/<id>`。
const String _menuRouteName = '/';
const String _entryRoutePrefix = '/entry/';

/// 抽屉内嵌 Navigator 的观察者：把「当前停在哪个入口」同步给 [SideDrawer]。
///
/// 页面栈变化只有这一个出口，比在每个入口页里埋回调可靠——用户在入口页里再进
/// 更新日志、日志查看等深层页面后返回，归属关系也不会丢。
class _DrawerEntryTracker extends NavigatorObserver {
  _DrawerEntryTracker(this.onEntryChanged);

  final void Function(String? entryId) onEntryChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _sync(newRoute);
  }

  /// 只认「当前栈顶」的路由。
  ///
  /// 还原上次位置时，初始栈会一次性塞入菜单 + 入口两条路由，通知按后进先出的顺序
  /// 分发，菜单那条最后到达；若不筛栈顶，会把刚还原的入口又覆盖回菜单。
  void _sync(Route<dynamic>? route) {
    if (route != null && !route.isCurrent) return;
    final name = route?.settings.name;
    if (name == _menuRouteName) {
      onEntryChanged(null);
    } else if (name != null && name.startsWith(_entryRoutePrefix)) {
      onEntryChanged(name.substring(_entryRoutePrefix.length));
    }
    // 入口页之下再压的深层页面（更新日志、日志查看等）不改归属：
    // 它们属于当前入口，从这类页面关掉抽屉仍应回到该入口
  }
}

/// 抽屉菜单项描述：icon 与 iconWidget 二选一。
///
/// [page] 与 [route] 二选一：前者在抽屉内嵌 Navigator 中展示，
/// 后者（如数据统计）会先关闭抽屉、再以根路由全屏打开。
class _MenuEntry {
  /// 稳定 id：用于记住「上次停在哪个入口」，必须与展示文案解耦
  final String id;
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final Widget? page;
  final String? route;

  const _MenuEntry({required this.id, this.icon, this.iconWidget, required this.label, this.page, this.route});
}

/// 数据统计入口：不进入设置列表，单独置顶展示。
const _MenuEntry _statisticsEntry = _MenuEntry(
  id: 'statistics',
  icon: Icons.insights_rounded,
  label: '数据统计',
  route: '/statistics',
);

/// 已合并入口的旧 id → 新 id。
///
/// 抽屉位置记忆跨版本存活（只在关闭时写一次），合并入口后旧 id 会查不到，
/// 直接退回菜单会让「刚点进快捷记录就关掉、立刻重开」落到一级菜单。这里把旧 id
/// 映射到合并后的入口，记忆窗口内的还原行为保持一致。
const Map<String, String> _legacyEntryIds = {
  'shortcuts': 'quick-record',
  'fixed-events': 'quick-record',
  'mi-fitness': 'health',
  'screen-usage': 'health',
};

/// 按 id 查入口；找不到（版本升级删过条目）时返回 null，由调用方退回菜单
_MenuEntry? _entryById(String id) {
  final resolvedId = _legacyEntryIds[id] ?? id;
  for (final entry in _menuEntries) {
    if (entry.id == resolvedId) return entry;
  }
  return null;
}

/// 抽屉入口清单：扁平一屏陈列，统一品牌色，不再按「设置/其他」分组
const List<_MenuEntry> _menuEntries = [
  _MenuEntry(id: 'profile', icon: Icons.person_outline, label: '个人信息', page: UserProfilePage()),
  _MenuEntry(
    id: 'q-settings',
    iconWidget: QAvatar(size: 36, withBackground: true),
    label: '小Q设置',
    page: QSettingsPage(),
  ),
  _MenuEntry(id: 'ai-config', icon: Icons.tune_rounded, label: 'AI 模型配置', page: AiConfigPage()),
  _MenuEntry(id: 'quick-record', icon: Icons.hexagon_outlined, label: '快捷记录', page: QuickRecordSettingsPage()),
  _MenuEntry(id: 'data', icon: Icons.sync_rounded, label: '数据与同步', page: DataSyncPage()),
  _MenuEntry(id: 'health', icon: Icons.favorite_border_rounded, label: '健康数据', page: HealthSettingsPage()),
  _MenuEntry(id: 'personalization', icon: Icons.palette_outlined, label: '个性化设置', page: PersonalizationPage()),
  _MenuEntry(id: 'about', icon: Icons.info_outline, label: '关于 QNote', page: AboutPage()),
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

    // 统一品牌色实心圆底：亮色主题下淡底 + 亮图标会糊在一起，
    // 实心底由 AppIconBadge 自动选黑/白前景，任意主题色都能看清
    final Widget leading = entry.iconWidget ?? AppIconBadge(icon: entry.icon!, size: 36, iconSize: 19);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      horizontalTitleGap: 14,
      minLeadingWidth: 0,
      leading: leading,
      title: Text(
        entry.label,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.onSurface),
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
