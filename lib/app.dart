import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/core/health/screen_usage_snapshot_service.dart';
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
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/widgets/floating_q/floating_q_overlay.dart';
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
    // 识图能力判定的同步查表依赖这份缓存，必须在首帧前预热
    ModelVisionCapability.loadFromPrefs(),
  ]);
}

class QNoteApp extends ConsumerStatefulWidget {
  const QNoteApp({super.key});

  @override
  ConsumerState<QNoteApp> createState() => _QNoteAppState();
}

class _QNoteAppState extends ConsumerState<QNoteApp> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.appone.qnote_flutter/widgets');
  static const _shareChannel = MethodChannel('com.appone.qnote_flutter/share');

  DateTime? _lastPausedTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initNavigationListener();
    _initExternalSharedTextListener();
    _runDeferredInitialization();
    _runStartupUpdateCheck();
    _runScreenUsageSnapshot(delay: const Duration(seconds: 2));
  }

  /// 屏幕时长每日快照：系统 UsageStats 只保留最近约 7 天，必须靠 App 主动把
  /// 逐日数值落库，统计页才能回看历史日期并做周/月聚合。
  ///
  /// 平台判断、权限、30 分钟节流都在服务内部完成，这里 fire-and-forget，
  /// 启动与回前台各触发一次即可保证数据持续累积。
  void _runScreenUsageSnapshot({bool force = false, Duration? delay}) async {
    if (delay != null) {
      await Future.delayed(delay);
      if (!mounted) {
        return;
      }
    }
    try {
      ref.read(screenUsageSnapshotServiceProvider).ensureSnapshot(force: force);
    } catch (e) {
      debugPrint('屏幕时长快照触发失败: $e');
    }
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

      // 小米运动健康启动自动同步（已授权 + 开关开启 + 距上次同步超 1 小时）
      try {
        final healthSyncService = ref.read(healthSyncServiceProvider);
        final authorized = await healthSyncService.isAuthorized();
        if (authorized) {
          final autoSync = await healthSyncService.getAutoSync();
          if (autoSync) {
            final lastSync = await healthSyncService.getLastSyncTime();
            final shouldSync = lastSync == null ||
                DateTime.now().difference(lastSync).inHours >= 1;
            if (shouldSync) {
              // fire-and-forget，不阻塞启动。窗口取 4 天：午睡可能发生在当天最后一次同步之后，
              // 窗口过窄会让那天永久停在缺午睡的错值上（落库按 date 主键整行 replace）
              healthSyncService.syncDays(daysBack: 4);
            }
          }
        }
      } catch (e) {
        LoggerService.instance.warning(
          '小米运动健康自动同步失败: $e',
          category: LogCategory.system,
        );
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
      _tryConsumePendingSharedText();
      _tryConsumePendingSharedImages();
      // 跨天后再回前台是补采前一日整日数值的关键时机，节流由服务内部把关
      _runScreenUsageSnapshot();
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

  /// 监听外部传入的内容（划选「给小Q」PROCESS_TEXT 或系统分享 SEND：文字/图片）
  void _initExternalSharedTextListener() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    _shareChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSharedText':
          final text = call.arguments as String?;
          if (text != null && text.trim().isNotEmpty) {
            _handleExternalSharedText(text.trim());
          }
        case 'onSharedImages':
          final paths =
              (call.arguments as List?)?.map((e) => e.toString()).toList() ??
                  const <String>[];
          if (paths.isNotEmpty) {
            _handleExternalSharedImages(paths);
          }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tryConsumePendingSharedText(retryCount: 2);
      await _tryConsumePendingSharedImages(retryCount: 2);
    });
  }

  Future<void> _tryConsumePendingSharedText({int retryCount = 0}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final pending = await _shareChannel.invokeMethod<String>('getPendingSharedText');
      if (pending != null && pending.trim().isNotEmpty) {
        _handleExternalSharedText(pending.trim());
      }
    } catch (e) {
      if (retryCount > 0) {
        await Future.delayed(const Duration(milliseconds: 200));
        await _tryConsumePendingSharedText(retryCount: retryCount - 1);
      } else {
        debugPrint('获取挂起外部分享文本失败: $e');
      }
    }
  }

  Future<void> _tryConsumePendingSharedImages({int retryCount = 0}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final pending =
          await _shareChannel.invokeMethod<List<dynamic>>('getPendingSharedImages');
      final paths = pending?.map((e) => e.toString()).toList() ?? const <String>[];
      if (paths.isNotEmpty) {
        _handleExternalSharedImages(paths);
      }
    } catch (e) {
      if (retryCount > 0) {
        await Future.delayed(const Duration(milliseconds: 200));
        await _tryConsumePendingSharedImages(retryCount: retryCount - 1);
      } else {
        debugPrint('获取挂起外部分享图片失败: $e');
      }
    }
  }

  /// 外部分享文字（划词/系统分享）：统一转为引用卡片挂起，
  /// 输入框保持空白由用户输入指令；发送时内容作为外部上下文注入，
  /// 不显示也不注入页面位置
  void _handleExternalSharedText(String text) {
    ref.read(floatingQProvider.notifier).openWithQuote(
          QTextQuote(
            source: QQuoteSource.external,
            sourceId: '',
            sourceTitle: '系统分享',
            quotedText: text,
          ),
        );
  }

  void _handleExternalSharedImages(List<String> paths) {
    ref.read(floatingQProvider.notifier).openWithImages(paths);
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
              child: Stack(
              children: [
                child ?? const SizedBox.shrink(),
                // 全局悬浮小Q入口：覆盖所有路由页面（含编辑器），内部自带隐藏规则。
                // 面板内 Tooltip 需要 Overlay 祖先，而 builder 子树位于路由 Navigator
                // 之外、无法找到路由内的 Overlay（否则 Tooltip 构建/展示时报错），
                // 故包一层局部 Overlay 作挂载根；小Q 自身经 Riverpod/InheritedWidget
                // 自更新，entry 闭包捕获 const 实例，应用重建不会导致其重挂载
                Overlay(
                  initialEntries: [
                    OverlayEntry(builder: (_) => const FloatingQOverlay()),
                  ],
                ),
              ],
            ),
            ),
          ),
        );
      },
    );
  }
}
