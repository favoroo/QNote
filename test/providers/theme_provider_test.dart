import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

Future<void> _waitForPrefs() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('旧 theme_mode 迁移成背景预设', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 2, 'accent_color': 0xFFE91E8C});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    container.read(accentColorProvider);
    await _waitForPrefs();

    final setting = container.read(backgroundSettingProvider);
    expect(setting.preset, AppBackgroundPreset.dark);
    expect(setting.customColor, AppBackgroundSetting.defaultCustomColor);
    expect(container.read(accentColorProvider), const Color(0xFFE91E8C));
  });

  test('切换 OLED 会持久化并同步旧 theme_mode', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    await _waitForPrefs();

    await container.read(backgroundSettingProvider.notifier).setPreset(AppBackgroundPreset.oled);

    final prefs = await SharedPreferences.getInstance();
    expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.oled);
    expect(prefs.getInt('background_preset'), AppBackgroundPreset.oled.index);
    expect(prefs.getInt('theme_mode'), ThemeMode.dark.index);
  });

  test('自定义颜色会切到 custom 并持久化', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    await _waitForPrefs();

    await container.read(backgroundSettingProvider.notifier).setCustomColor(const Color(0xFF336699));

    final prefs = await SharedPreferences.getInstance();
    final setting = container.read(backgroundSettingProvider);
    expect(setting.preset, AppBackgroundPreset.custom);
    expect(setting.customColor, const Color(0xFF336699));
    expect(prefs.getInt('background_preset'), AppBackgroundPreset.custom.index);
    expect(prefs.getInt('background_custom_color'), 0xFF336699);
    // #336699 偏暗，旧 theme_mode 应回写为深色
    expect(prefs.getInt('theme_mode'), ThemeMode.dark.index);
  });

  test('恢复默认会重置预设与自定义色', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(backgroundSettingProvider);
    await _waitForPrefs();

    final notifier = container.read(backgroundSettingProvider.notifier);
    await notifier.setPreset(AppBackgroundPreset.oled);
    await notifier.setCustomColor(const Color(0xFF336699));
    await notifier.reset();

    final prefs = await SharedPreferences.getInstance();
    final setting = container.read(backgroundSettingProvider);
    expect(setting.preset, AppBackgroundPreset.system);
    expect(setting.customColor, AppBackgroundSetting.defaultCustomColor);
    expect(prefs.getInt('background_preset'), AppBackgroundPreset.system.index);
    expect(prefs.getInt('theme_mode'), ThemeMode.system.index);
  });
}
