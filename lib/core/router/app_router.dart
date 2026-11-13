import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/pages/diary_page.dart';
import 'package:qnote_flutter/pages/notes_page.dart';
import 'package:qnote_flutter/pages/todo_page.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/pages/statistics_page.dart';
import 'package:qnote_flutter/pages/settings/user_profile_page.dart';
import 'package:qnote_flutter/pages/settings/q_settings_page.dart';
import 'package:qnote_flutter/pages/settings/q_memory_page.dart';
import 'package:qnote_flutter/pages/settings/q_personality_page.dart';
import 'package:qnote_flutter/pages/settings/q_skills_page.dart';
import 'package:qnote_flutter/pages/settings/ai_provider_edit_page.dart';
import 'package:qnote_flutter/pages/settings/ai_route_group_edit_page.dart';
import 'package:qnote_flutter/widgets/ai/no_model_guide.dart';
import 'package:qnote_flutter/pages/settings/quick_record_settings_page.dart';
import 'package:qnote_flutter/pages/settings/health_settings_page.dart';
import 'package:qnote_flutter/pages/settings/data_sync_page.dart';
import 'package:qnote_flutter/pages/health/health_metric_detail_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/about_page.dart';
import 'package:qnote_flutter/widgets/diary/diary_editor_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_batch_manage_view.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';
import 'package:qnote_flutter/widgets/bottom_nav_bar.dart';
import 'package:qnote_flutter/widgets/shell_branch_container.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';

/// 根导航键。
///
/// 对外暴露是因为「检查更新」弹窗等全局 UI 需要在任意位置弹出对话框，
/// 而 MaterialApp 自身的 context 位于 Navigator 之上，无法直接 showDialog。
/// 通过该 key 的 currentContext 可以拿到有效的 Navigator context。
final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/diary',
    // 模态路由观察者：Dialog/BottomSheet 打开时全局悬浮小Q自动隐藏
    observers: [FloatingQModalRouteObserver()],
    routes: [
      StatefulShellRoute(
        builder: (context, state, navigationShell) {
          return ScaffoldWithNavBar(navigationShell: navigationShell);
        },
        // 分支切换过渡收在自定义容器里：记录板块内切换零位移，其他分支带微位移溶解。
        navigatorContainerBuilder: (context, navigationShell, children) {
          return ShellBranchContainer(currentIndex: navigationShell.currentIndex, children: children);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/diary',
                builder: (context, state) => const DiaryPage(),
                routes: [
                  GoRoute(
                    path: 'editor',
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (context, state) {
                      final record = state.extra as DiaryRecord?;
                      // P2-37: 复用 _fadeTransitionPage helper，避免重复 transitionsBuilder
                      return _fadeTransitionPage(record != null ? DiaryEditorView(record: record) : const DiaryPage());
                    },
                  ),
                  GoRoute(
                    path: 'batch',
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (context, state) {
                      final extra = state.extra as Map<String, dynamic>?;
                      final initialTags = extra?['initialTags'] as List<String>?;
                      final initialDateRange = extra?['initialDateRange'] as DateTimeRange?;
                      return _fadeTransitionPage(
                        DiaryBatchManageView(initialTags: initialTags, initialDateRange: initialDateRange),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/notes',
                builder: (context, state) => const NotesPage(),
                routes: [
                  GoRoute(
                    path: 'editor',
                    parentNavigatorKey: rootNavigatorKey,
                    pageBuilder: (context, state) {
                      final note = state.extra as Note?;
                      // P2-37: 复用 _fadeTransitionPage helper
                      return _fadeTransitionPage(note != null ? NoteEditorView(note: note) : const NotesPage());
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/todo', builder: (context, state) => const TodoPage())],
          ),
          // /ai 小Q全页面：不作为导航栏 tab 显示，由中央停靠按钮单击进入
          StatefulShellBranch(
            routes: [GoRoute(path: '/ai', builder: (context, state) => const AiPage())],
          ),
        ],
      ),
      GoRoute(
        // 数据统计已移出底栏：从抽屉以根路由全屏打开，返回即回到原分支
        path: '/statistics',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const StatisticsPage()),
      ),
      GoRoute(
        path: '/settings/profile',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const UserProfilePage()),
      ),
      GoRoute(
        path: '/settings/q-settings',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final tabStr = state.uri.queryParameters['tab'];
          final initialTab = tabStr != null ? int.tryParse(tabStr) ?? 0 : 0;
          return _fadeTransitionPage(QSettingsPage(initialTab: initialTab));
        },
      ),
      GoRoute(
        path: '/settings/q-memory',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const QMemoryPage()),
      ),
      GoRoute(
        path: '/settings/q-skills',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const QSkillsPage()),
      ),
      GoRoute(
        path: '/settings/q-personality',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const QPersonalityPage()),
      ),
      GoRoute(
        // 模型配置已并入小Q设置的「模型」分段；旧路径保留并直接定位到该分段，
        // 让所有「去配置模型」的引导链接都落到同一处，不再维护第二套独立配置页
        path: '/settings/ai-config',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final args = state.extra is AiConfigPageArgs ? state.extra as AiConfigPageArgs : const AiConfigPageArgs();
          return _fadeTransitionPage(QSettingsPage(initialTab: 0, autoOpenAddModelService: args.autoOpenAdd));
        },
      ),
      GoRoute(
        path: '/settings/ai-config/provider',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final args = state.extra is AiProviderEditArgs
              ? state.extra as AiProviderEditArgs
              : const AiProviderEditArgs();
          return _fadeTransitionPage(
            AiProviderEditPage(provider: args.provider, initialVendorId: args.initialVendorId),
          );
        },
      ),
      GoRoute(
        path: '/settings/ai-config/route-group',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final args = state.extra is AiRouteGroupEditArgs
              ? state.extra as AiRouteGroupEditArgs
              : const AiRouteGroupEditArgs();
          return _fadeTransitionPage(AiRouteGroupEditPage(group: args.group));
        },
      ),
      GoRoute(
        // 快捷记录：快捷按钮与固定事件合并为一个入口，用 query 定位分段
        path: '/settings/shortcuts',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            _fadeTransitionPage(QuickRecordSettingsPage(initialTab: _quickRecordTab(state.uri.queryParameters['tab']))),
      ),
      GoRoute(
        // 旧「固定事件」路径保留，统一重定向到快捷记录页的固定事件分段
        // （该路由历史上不带 extra，重定向不会丢参数）
        path: '/settings/fixed-events',
        redirect: (context, state) => '/settings/shortcuts?tab=fixed-events',
      ),
      GoRoute(
        path: '/settings/data',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          // tab: sync(默认) / backup / maintenance
          final tab = switch (state.uri.queryParameters['tab']) {
            'backup' => 1,
            'maintenance' => 2,
            _ => 0,
          };
          return _fadeTransitionPage(DataSyncPage(initialTab: tab));
        },
      ),
      GoRoute(
        // 旧同步设置路径保留，统一重定向到数据与同步页的云同步分区
        path: '/settings/sync',
        redirect: (context, state) => '/settings/data?tab=sync',
      ),
      GoRoute(
        // 健康数据：运动健康与屏幕使用时间合并为一个入口，用 query 定位分段
        path: '/settings/mi-fitness',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final initialDate = state.extra as DateTime?;
          return _fadeTransitionPage(
            HealthSettingsPage(initialTab: _healthTab(state.uri.queryParameters['tab']), initialDate: initialDate),
          );
        },
      ),
      GoRoute(
        // 旧「屏幕使用时间」路径保留：直接构建合并页并定位到屏幕使用分段。
        // 不用 redirect——redirect 会丢掉 extra 里的日期，而日记日结卡片正是带日期跳过来的。
        path: '/settings/screen-usage',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) =>
            _fadeTransitionPage(HealthSettingsPage(initialTab: 1, initialDate: state.extra as DateTime?)),
      ),
      GoRoute(
        // 健康指标二级详情页：数据由主看板通过 extra 带入，不自己查库
        path: '/health-detail',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final args =
              state.extra as HealthDetailArgs? ?? const HealthDetailArgs(kind: HealthMetricKind.vitals, title: '健康详情');
          return _fadeTransitionPage(HealthMetricDetailPage(args: args));
        },
      ),
      GoRoute(
        path: '/settings/personalization',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const PersonalizationPage()),
      ),
      GoRoute(
        path: '/settings/about',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const AboutPage()),
      ),
      GoRoute(
        path: '/quick_record',
        redirect: (context, state) {
          final actionStr = state.uri.queryParameters['action'];
          WidgetAction? action;
          if (actionStr == 'input') {
            action = WidgetAction.input;
          } else if (actionStr == 'photo') {
            action = WidgetAction.photo;
          } else if (actionStr == 'camera') {
            action = WidgetAction.camera;
          } else if (actionStr == 'send') {
            action = WidgetAction.send;
          }

          if (action != null) {
            ref.read(pendingWidgetActionProvider.notifier).state = action;
          }
          return '/diary';
        },
      ),
    ],
  );
});

/// 快捷记录页的分段：`?tab=fixed-events` → 固定事件（1），其余为快捷按钮（0）
int _quickRecordTab(String? tab) => tab == 'fixed-events' ? 1 : 0;

/// 健康数据页的分段：`?tab=screen` → 屏幕使用（1），其余为运动健康（0）
int _healthTab(String? tab) => tab == 'screen' ? 1 : 0;

/// 设置页与二级路由的统一转场：淡入 + 轻微上移。
///
/// 只做 2% 屏高的位移，既让页面有「从下方进入」的方向感，又不会在快速
/// 连续打开设置页时产生拖沓；返回时用 [AppCurves.exit] 快速退场。
CustomTransitionPage _fadeTransitionPage(Widget child) {
  return CustomTransitionPage(
    child: child,
    transitionDuration: AppDurations.page,
    reverseTransitionDuration: AppDurations.normal,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // 系统开启减弱动效时直接呈现终态，不做任何位移/淡入。
      if (MediaQuery.disableAnimationsOf(context)) return child;

      final curved = CurvedAnimation(parent: animation, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  );
}
