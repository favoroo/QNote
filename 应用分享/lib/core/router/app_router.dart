import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/pages/diary_page.dart';
import 'package:qnote_flutter/pages/notes_page.dart';
import 'package:qnote_flutter/pages/todo_page.dart';
import 'package:qnote_flutter/pages/ai_page.dart';
import 'package:qnote_flutter/pages/statistics_page.dart';
import 'package:qnote_flutter/pages/settings/user_profile_page.dart';
import 'package:qnote_flutter/pages/settings/ai_config_page.dart';
import 'package:qnote_flutter/pages/settings/shortcuts_page.dart';
import 'package:qnote_flutter/pages/settings/data_management_page.dart';
import 'package:qnote_flutter/pages/settings/sync_settings_page.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/pages/settings/about_page.dart';
import 'package:qnote_flutter/widgets/diary/diary_editor_view.dart';
import 'package:qnote_flutter/widgets/diary/diary_batch_manage_view.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';
import 'package:qnote_flutter/widgets/bottom_nav_bar.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/diary',
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
                    parentNavigatorKey: _rootNavigatorKey,
                    pageBuilder: (context, state) {
                      final record = state.extra as DiaryRecord?;
                      return CustomTransitionPage(
                        child: record != null ? DiaryEditorView(record: record) : const DiaryPage(),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          return FadeTransition(
                            opacity: CurveTween(curve: Curves.easeInOut).animate(animation),
                            child: child,
                          );
                        },
                        transitionDuration: const Duration(milliseconds: 250),
                      );
                    },
                  ),
                  GoRoute(
                    path: 'batch',
                    parentNavigatorKey: _rootNavigatorKey,
                    pageBuilder: (context, state) {
                      return CustomTransitionPage(
                        child: const DiaryBatchManageView(),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          return FadeTransition(
                            opacity: CurveTween(curve: Curves.easeInOut).animate(animation),
                            child: child,
                          );
                        },
                        transitionDuration: const Duration(milliseconds: 250),
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
                    parentNavigatorKey: _rootNavigatorKey,
                    pageBuilder: (context, state) {
                      final note = state.extra as Note?;
                      return CustomTransitionPage(
                        child: note != null ? NoteEditorView(note: note) : const NotesPage(),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          return FadeTransition(
                            opacity: CurveTween(curve: Curves.easeInOut).animate(animation),
                            child: child,
                          );
                        },
                        transitionDuration: const Duration(milliseconds: 250),
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
                builder: (context, state) => const TodoPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/ai',
                builder: (context, state) => const AiPage(),
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
        ],
      ),
      GoRoute(
        path: '/settings/profile',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const UserProfilePage()),
      ),
      GoRoute(
        path: '/settings/ai-config',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const AiConfigPage()),
      ),
      GoRoute(
        path: '/settings/shortcuts',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const ShortcutsPage()),
      ),
      GoRoute(
        path: '/settings/data',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const DataManagementPage()),
      ),
      GoRoute(
        path: '/settings/sync',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const SyncSettingsPage()),
      ),
      GoRoute(
        path: '/settings/personalization',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const PersonalizationPage()),
      ),
      GoRoute(
        path: '/settings/about',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => _fadeTransitionPage(const AboutPage()),
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
