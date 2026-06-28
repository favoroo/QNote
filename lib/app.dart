import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/database_init.dart'
    if (dart.library.io) 'package:qnote_flutter/database_init_io.dart';
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

  /// P2-35: 初始化完成标志。false 时显示 splash，true 时显示主应用。
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // P2-35: observer 与导航监听延迟到初始化完成后注册，避免初始化期间
    // lifecycle 回调或原生导航请求访问未就绪的数据库。
    _initializeApp();
  }

  /// P2-35: 后台并行初始化。
  ///
  /// 第一批并行：Logger / 日期格式化 / 数据库工厂（三者无依赖）。
  /// 第二批：打开数据库（依赖工厂）。
  /// 第三批并行：4 个默认配置初始化（依赖数据库）。
  /// 最后：WebDAV 同步检查 + 通知服务启动。
  Future<void> _initializeApp() async {
    try {
      // 第一批：无依赖的初始化并行执行
      await Future.wait([
        LoggerService.instance.init(),
        initializeDateFormatting('zh_CN'),
        initDatabaseFactory(),
      ]);

      // 第二批：打开数据库（依赖工厂）
      await DatabaseHelper.instance.database;

      // 第三批：依赖数据库的默认配置初始化并行执行
      final configRepo = ConfigRepository.instance;
      await Future.wait([
        configRepo.ensureDefaultShortcuts(),
        configRepo.ensureDefaultAiConfigs(),
        AiRoleService.instance.initAndEnsureDefaults(),
        NotificationService.instance.init(),
      ]);

      // 最后：WebDAV 自动同步检查 + 通知提醒启动
      final webdavConfig = await configRepo.getWebdavConfig();
      if (webdavConfig != null && webdavConfig.autoSync) {
        SyncScheduler.instance.syncIfNeeded();
      }
      NotificationService.instance.startReminderCheck();
    } catch (e, stackTrace) {
      LoggerService.instance.error(
        '应用初始化失败: $e',
        category: LogCategory.system,
        details: stackTrace.toString(),
      );
    } finally {
      if (mounted) {
        // 初始化完成后注册生命周期观察者和导航监听
        WidgetsBinding.instance.addObserver(this);
        _initNavigationListener();
        setState(() => _initialized = true);
      }
    }
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

  void _navigateToRoute(String route, {int retryCount = 3}) {
    try {
      final router = ref.read(routerProvider);
      router.go(route);
    } catch (e) {
      debugPrint('路由导航失败: $e');
      // 导航可能因路由器正在过渡而失败，延迟重试
      if (retryCount > 0) {
        Future.delayed(const Duration(milliseconds: 300), () {
          _navigateToRoute(route, retryCount: retryCount - 1);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // P2-35: 初始化未完成时显示 splash，不 watch 任何依赖数据库的 Provider
    if (!_initialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme(AppTheme.primaryDefault),
        darkTheme: AppTheme.darkTheme(AppTheme.primaryDefault),
        home: const _SplashScreen(),
      );
    }

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

/// P2-35: 启动 splash 页，在后台初始化完成前显示。
///
/// 用 AppTheme.primaryDefault 与主应用保持视觉一致，避免主题切换跳变。
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_rounded,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

