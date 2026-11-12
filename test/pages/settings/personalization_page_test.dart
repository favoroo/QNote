import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
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
    expect(find.text('主题色'), findsNWidgets(2));
    expect(find.text('自定义'), findsOneWidget);
    expect(find.text('恢复默认设置'), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.dark);

    await tester.tap(find.text('OLED 纯黑'));
    await tester.pump();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.oled);

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
