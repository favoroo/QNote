import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/router/app_router.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';
import 'package:flutter/services.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';

class QNoteApp extends ConsumerStatefulWidget {
  const QNoteApp({super.key});

  @override
  ConsumerState<QNoteApp> createState() => _QNoteAppState();
}

class _QNoteAppState extends ConsumerState<QNoteApp> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.appone.qnote_flutter/widgets');

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
    if (state == AppLifecycleState.resumed) {
      _refreshProviders();
    }
  }

  void _refreshProviders() {
    try {
      ref.read(diaryListProvider.notifier).refresh();
      ref.read(todoListProvider.notifier).refresh();
    } catch (_) {}
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

    // 检查是否有冷启动挂起的路由
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pending = await _channel.invokeMethod<String>('getPendingRoute');
        if (pending != null) {
          _navigateToRoute(pending);
        }
      } catch (_) {}
    });
  }

  void _navigateToRoute(String route) {
    try {
      final router = ref.read(routerProvider);
      router.go(route);
    } catch (_) {}
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
        return GestureDetector(
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
        );
      },
    );
  }
}

