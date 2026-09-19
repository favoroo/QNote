import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/shortcuts_page.dart';
import 'package:qnote_flutter/pages/settings/fixed_events_page.dart';
import 'package:qnote_flutter/pages/settings/data_sync_page.dart';
import 'package:qnote_flutter/pages/settings/mi_fitness_settings_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/about_page.dart';
import 'package:qnote_flutter/widgets/diary/diary_editor_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_batch_manage_view.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';
import 'package:qnote_flutter/widgets/bottom_nav_bar.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';

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
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return ScaffoldWithNavBar(navigationShell: navigationShell);
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
                      return _fadeTransitionPage(
                        record != null ? DiaryEditorView(record: record) : const DiaryPage(),
                      );
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
                        DiaryBatchManageView(
                          initialTags: initialTags,
                          initialDateRange: initialDateRange,
                        ),
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
                      return _fadeTransitionPage(
                        note != null ? NoteEditorView(note: note) : const NotesPage(),
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
                path: '/todo',
                // 待办小组件「+」按钮经 /todo?add=1 进入：置位一次性标志后正常构建，
                // TodoPage 消费标志自动弹出添加弹窗（redirect 在 build 之外执行，置位安全）
                redirect: (context, state) {
                  if (state.uri.queryParameters['add'] == '1') {
                    ref.read(pendingTodoAddProvider.notifier).state = true;
                  }
                  return null;
                },
                builder: (context, state) => const TodoPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/statistics',
                builder: (context, state) => const StatisticsPage(),
              ),
            ],
          ),
          // /ai 小Q全页面：不作为导航栏 tab 显示，由中央停靠按钮单击进入
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/ai',
                builder: (context, state) => const AiPage(),
              ),
            ],
          ),
        ],
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
        path: '/settings/ai-config',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const AiConfigPage()),
      ),
      GoRoute(
        path: '/settings/shortcuts',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const ShortcutsPage()),
      ),
      GoRoute(
        path: '/settings/fixed-events',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const FixedEventsPage()),
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
        path: '/settings/mi-fitness',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final initialDate = state.extra as DateTime?;
          return _fadeTransitionPage(MiFitnessSettingsPage(initialDate: initialDate));
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
          if (actionStr == 'input') action = WidgetAction.input;
          else if (actionStr == 'photo') action = WidgetAction.photo;
          else if (actionStr == 'camera') action = WidgetAction.camera;
          else if (actionStr == 'send') action = WidgetAction.send;

          if (action != null) {
            ref.read(pendingWidgetActionProvider.notifier).state = action;
          }
          return '/diary';
        },
      ),
    ],
  );
});

/// Smooth fade page transition for settings and sub-routes
CustomTransitionPage _fadeTransitionPage(Widget child) {
  return CustomTransitionPage(
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurveTween(curve: Curves.easeInOut).animate(animation),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 250),
  );
}
