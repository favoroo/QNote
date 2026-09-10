import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/core/network/update_service.dart';
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
import 'package:qnote_flutter/widgets/update_dialog.dart';

/// 关键路径初始化：必须在 runApp 前完成，确保数据库和配置就绪。
///
/// 包括：Logger、日期格式化、数据库工厂、打开数据库、默认配置（快捷键/AI配置/AI角色/通知服务初始化）。
Future<void> preInitializeApp() async {
  await Future.wait([
    LoggerService.instance.init(),
    initializeDateFormatting('zh_CN'),
    initDatabaseFactory(),
  ]);

  await DatabaseHelper.instance.database;

  // 版本号从构建产物读取，在任何 widget 引用前完成初始化
  await AppVersion.init();

  final configRepo = ConfigRepository.instance;
  await Future.wait([
    configRepo.ensureDefaultShortcuts(),
    configRepo.ensureDefaultAiConfigs(),
    AiRoleService.instance.initAndEnsureDefaults(),
    NotificationService.instance.init(),
  ]);
}

class QNoteApp extends ConsumerStatefulWidget {
  const QNoteApp({super.key});

  @override
  ConsumerState<QNoteApp> createState() => _QNoteAppState();
}

class _QNoteAppState extends ConsumerState<QNoteApp> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.appone.qnote_flutter/widgets');

  DateTime? _lastPausedTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initNavigationListener();
    _runDeferredInitialization();
    _runStartupUpdateCheck();
  }

  /// 延迟初始化：主界面显示后执行，不阻塞首帧。
  ///
  /// 包括：WebDAV 自动同步检查、通知提醒启动。
  Future<void> _runDeferredInitialization() async {
    try {
      final configRepo = ConfigRepository.instance;
      final webdavConfig = await configRepo.getWebdavConfig();
      if (webdavConfig != null && webdavConfig.autoSync) {
        SyncScheduler.instance.syncIfNeeded();
      }
      NotificationService.instance.startReminderCheck();
    } catch (e, stackTrace) {
      LoggerService.instance.error(
        '延迟初始化失败: $e',
        category: LogCategory.system,
        details: stackTrace.toString(),
      );
    }
  }

  /// 启动时静默检查应用更新。
  ///
  /// 仅 Android 生效：iOS 走 App Store 分发，Web 端不存在 APK 更新。
  /// 无更新或请求失败一律静默处理，不打扰用户。
  Future<void> _runStartupUpdateCheck() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      // 延后执行，避免与首帧渲染、WebDAV 自动同步抢占资源
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted) return;

      // 检查用户是否开启自动更新，以及 24 小时频次节流
      final shouldCheck = await UpdateService.instance.shouldRunStartupCheck();
      if (!shouldCheck || !mounted) return;

      final result = await UpdateService.instance.checkForUpdate();
      // 记录本次检查时间，保证 24 小时频次节流生效
      await UpdateService.instance.recordCheckTime();

      if (!mounted || result.status != UpdateCheckStatus.available) return;

      final updateInfo = result.updateInfo;
      if (updateInfo == null) return;

      // showDialog 需要 Navigator 之下的 context，根节点 key 是唯一稳定来源
      final dialogContext = rootNavigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;

      await showUpdateDialog(
        context: dialogContext,
        updateInfo: updateInfo,
        currentVersion: AppVersion.version,
      );
    } catch (e, stackTrace) {
      LoggerService.instance.warning(
        '启动检查更新失败: $e',
        category: LogCategory.system,
        details: stackTrace.toString(),
      );
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
      _tryNavigatePendingRoute();
    }
  }

  Future<void> _refreshProvidersIfNeeded() async {
    try {
      final baseline = _lastPausedTime;
      if (baseline == null) {
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
    if (kIsWeb) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'navigate') {
        final route = call.arguments as String?;
        if (route != null) {
          _navigateToRoute(route);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tryNavigatePendingRoute(retryCount: 2);
    });
  }

  Future<void> _tryNavigatePendingRoute({int retryCount = 0}) async {
    if (kIsWeb) return;

    try {
      final pending = await _channel.invokeMethod<String>('getPendingRoute');
      if (pending != null) {
        _navigateToRoute(pending);
      }
    } catch (e) {
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
      if (retryCount > 0) {
        Future.delayed(const Duration(milliseconds: 300), () {
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
