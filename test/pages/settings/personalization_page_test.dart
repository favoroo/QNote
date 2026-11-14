import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/theme/appearance_bootstrap.dart';
import 'package:qnote_flutter/pages/settings/personalization_page.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

Future<void> _waitForPrefs() => Future<void>.delayed(const Duration(milliseconds: 30));

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('个性化设置页展示背景预设并切换', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    expect(find.text('背景'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('OLED 纯黑'), findsOneWidget);
    expect(find.text('暖纸'), findsOneWidget);
    expect(find.text('雾蓝'), findsOneWidget);
    expect(find.text('松林'), findsOneWidget);
    expect(find.text('主题色'), findsNWidgets(2));
    expect(find.text('自定义'), findsOneWidget);
    expect(find.text('恢复默认设置'), findsOneWidget);

    await tester.tap(find.text('松林'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.pine);

    await tester.tap(find.text('暖纸'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.paper);

    await tester.tap(find.text('深色'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.dark);

    await tester.tap(find.text('OLED 纯黑'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.oled);

    await tester.ensureVisible(find.text('恢复默认设置'));
    await tester.pump();
    await tester.tap(find.text('恢复默认设置'));
    await tester.pump();
    final setting = container.read(backgroundSettingProvider);
    expect(setting.preset, AppBackgroundPreset.system);
    expect(setting.customColor, AppBackgroundSetting.defaultCustomColor);
  });

  testWidgets('自定义背景打开拾色对话框', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    expect(find.text('自定义背景色'), findsOneWidget);
    expect(find.text('实际背景预览'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('自定义背景色'), findsNothing);
  });

  testWidgets('自定义主题色打开拾色对话框', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    container.read(accentColorProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    expect(find.text('自定义颜色'), findsOneWidget);
    expect(find.byIcon(Icons.palette_outlined), findsOneWidget);

    await tester.ensureVisible(find.text('自定义颜色'));
    await tester.pump();
    await tester.tap(find.text('自定义颜色'));
    await tester.pumpAndSettle();

    expect(find.text('自定义主题色'), findsOneWidget);
    expect(find.text('主题色预览'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsNothing);
  });

  testWidgets('自定义主题色生效后入口展示色值', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(() async {
      await container.read(accentColorProvider.notifier).setAccentColor(const Color(0xFF123456));
    });
    await tester.pump();

    expect(container.read(accentColorProvider).toARGB32(), 0xFF123456);
    expect(find.text('#123456'), findsOneWidget);
    expect(find.byIcon(Icons.palette_outlined), findsNothing);
  });

  testWidgets('推荐搭配一键同时应用背景与主题色', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    container.read(accentColorProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    expect(find.text('推荐搭配'), findsOneWidget);
    expect(find.text('蓝橙电波'), findsOneWidget);

    await tester.tap(find.text('蓝橙电波'));
    await tester.pump();

    final setting = container.read(backgroundSettingProvider);
    expect(setting.preset, AppBackgroundPreset.custom);
    expect(setting.customColor.toARGB32(), 0xFF002FA7);
    expect(container.read(accentColorProvider).toARGB32(), 0xFFFF6B18);

    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(AppearanceKeys.backgroundPreset), AppBackgroundPreset.custom.index);
      expect(prefs.getInt(AppearanceKeys.backgroundCustomColor), 0xFF002FA7);
      expect(prefs.getInt(AppearanceKeys.accentColor), 0xFFFF6B18);
    });
  });

  testWidgets('第 9 个槽位可保存当前搭配并再次套用', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    container.read(accentColorProvider);
    container.read(savedColorSchemeProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    expect(find.text('保存当前'), findsOneWidget);
    expect(find.text('我的搭配'), findsNothing);

    // 先选中「赤焰黑」，再把当前外观存进第 9 格
    await tester.tap(find.text('赤焰黑'));
    await tester.pump();
    await tester.runAsync(_waitForPrefs);

    await tester.tap(find.text('保存当前'));
    await tester.pump();
    expect(find.text('我的搭配'), findsOneWidget);
    expect(container.read(savedColorSchemeProvider), isNotNull);

    // 换成另一套后，点「我的搭配」应恢复回 OLED + 正红
    await tester.tap(find.text('雾蓝琥珀'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.custom);
    expect(container.read(accentColorProvider).toARGB32(), 0xFFB45309);

    await tester.tap(find.text('我的搭配'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.oled);
    expect(container.read(accentColorProvider).toARGB32(), 0xFFF80004);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('我的搭配角标菜单可用当前搭配覆盖', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    container.read(accentColorProvider);
    container.read(savedColorSchemeProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    await tester.tap(find.text('保存当前'));
    await tester.pump();
    expect(container.read(savedColorSchemeProvider), isNotNull);

    // 换成「赤焰黑」后再覆盖，槽位应记录新的外观
    await tester.tap(find.text('赤焰黑'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用当前搭配覆盖'));
    await tester.pumpAndSettle();

    final saved = container.read(savedColorSchemeProvider);
    expect(saved, isNotNull);
    expect(saved!.background.preset, AppBackgroundPreset.oled);
    expect(saved.accentColor.toARGB32(), 0xFFF80004);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('我的搭配角标菜单可删除已保存搭配', (tester) async {
    _useTallSurface(tester);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    container.read(accentColorProvider);
    container.read(savedColorSchemeProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();

    await tester.tap(find.text('保存当前'));
    await tester.pump();
    expect(find.text('我的搭配'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(find.text('用当前搭配覆盖'), findsOneWidget);
    expect(find.text('删除我的搭配'), findsOneWidget);

    await tester.tap(find.text('删除我的搭配'));
    await tester.pumpAndSettle();
    expect(container.read(savedColorSchemeProvider), isNull);
    expect(find.text('保存当前'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('窄屏下背景卡片与拾色器不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.lightTheme(AppTheme.primaryDefault), home: const PersonalizationPage()),
      ),
    );
    await tester.runAsync(_waitForPrefs);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('自定义'));
    await tester.pump();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('自定义背景色'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
