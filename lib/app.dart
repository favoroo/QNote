import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';

class QNoteApp extends ConsumerStatefulWidget {
  const QNoteApp({super.key});

  @override
  ConsumerState<QNoteApp> createState() => _QNoteAppState();
}

class _QNoteAppState extends ConsumerState<QNoteApp> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.appone.qnote_flutter/widgets');

  /// 最近一次进入后台的时刻，用于在 resume 时判断是否真有数据变更
  DateTime? _lastPausedTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initNavigationListener();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lastPausedTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _refreshProvidersIfNeeded();
      // APP 恢复前台后拉取小组件挂起路由，确保在 Provider 刷新之后执行导航
      _tryNavigatePendingRoute();
    }
  }

  /// 仅在数据库自上次切后台以来有 sync_log 变更时才 refresh，
  /// 避免每次切回前台都触发无谓的 2 次全表查询
  Future<void> _refreshProvidersIfNeeded() async {
    try {
      final baseline = _lastPausedTime;
      if (baseline == null) {
        // 冷启动后首次 resume，没有基线，保守 refresh
        _refreshProviders();
        return;
      }
      final changes = await SyncLogRepository.instance.getChangesSince(baseline);
      if (changes.isEmpty) {
        return;
      }
      _refreshProviders();
    } catch (e) {
      debugPrint('检查 sync_log 失败，回退到 refresh: $e');
      _refreshProviders();
    }
  }

  void _refreshProviders() {
    try {
      ref.read(diaryListProvider.notifier).refresh();
      ref.read(todoListProvider.notifier).refresh();
    } catch (e) {
      debugPrint('刷新 Provider 失败: $e');
    }
  }

  void _initNavigationListener() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'navigate') {
        final route = call.arguments as String?;
        if (route != null) {
          _navigateToRoute(route);
        }
      }
    });

    // 冷启动时拉取挂起路由，带延迟重试以等待 MethodChannel 就绪
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tryNavigatePendingRoute(retryCount: 2);
    });
  }

  /// 从原生侧拉取挂起路由并导航，retryCount 为重试次数
  Future<void> _tryNavigatePendingRoute({int retryCount = 0}) async {
    try {
      final pending = await _channel.invokeMethod<String>('getPendingRoute');
      if (pending != null) {
        _navigateToRoute(pending);
      }
    } catch (e) {
      // MethodChannel 可能尚未就绪，延迟重试
      if (retryCount > 0) {
        await Future.delayed(const Duration(milliseconds: 200));
        await _tryNavigatePendingRoute(retryCount: retryCount - 1);
      } else {
        debugPrint('获取挂起路由失败: $e');
      }
    }
  }

  void _navigateToRoute(String route, {int retryCount = 1}) {
    try {
      final router = ref.read(routerProvider);
      router.go(route);
    } catch (e) {
      debugPrint('路由导航失败: $e');
      // 导航可能因路由器正在过渡而失败，延迟重试
      if (retryCount > 0) {
        Future.delayed(const Duration(milliseconds: 200), () {
          _navigateToRoute(route, retryCount: retryCount - 1);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final accentColor = ref.watch(accentColorProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'QNote',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(accentColor),
      darkTheme: AppTheme.darkTheme(accentColor),
      themeMode: themeMode,
      routerConfig: router,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),
      builder: (context, child) {
        final theme = Theme.of(context);
        final style = SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: theme.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: theme.brightness == Brightness.dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: theme.colorScheme.surface,
          systemNavigationBarIconBrightness: theme.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
        );

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: style,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (didPop) return;
                final router = GoRouter.of(context);
                final location = router.routerDelegate.currentConfiguration.uri.toString();
                final shellRoutes = ['/diary', '/notes', '/todo', '/ai', '/statistics'];
                if (shellRoutes.contains(location)) {
                  return;
                }
                router.pop();
              },
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}

