import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/app_color_schemes.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/appearance_bootstrap.dart';
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

  test('保存/删除「我的搭配」会读写持久化', () async {
    SharedPreferences.setMockInitialValues({});

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(savedColorSchemeProvider);
    await _waitForPrefs();

    const background = AppBackgroundSetting(preset: AppBackgroundPreset.oled, customColor: Color(0xFF123456));
    await container.read(savedColorSchemeProvider.notifier).save(background, const Color(0xFFF80004));

    final saved = container.read(savedColorSchemeProvider);
    expect(saved, isNotNull);
    expect(saved!.name, savedColorSchemeName);
    expect(saved.background.preset, AppBackgroundPreset.oled);
    expect(saved.accentColor, const Color(0xFFF80004));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(AppearanceKeys.savedSchemeBackgroundPreset), AppBackgroundPreset.oled.index);
    expect(prefs.getInt(AppearanceKeys.savedSchemeBackgroundCustomColor), 0xFF123456);
    expect(prefs.getInt(AppearanceKeys.savedSchemeAccentColor), 0xFFF80004);

    await container.read(savedColorSchemeProvider.notifier).clear();
    expect(container.read(savedColorSchemeProvider), isNull);
    expect(prefs.getInt(AppearanceKeys.savedSchemeBackgroundPreset), isNull);
    expect(prefs.getInt(AppearanceKeys.savedSchemeBackgroundCustomColor), isNull);
    expect(prefs.getInt(AppearanceKeys.savedSchemeAccentColor), isNull);
  });

  test('冷启动能从偏好恢复「我的搭配」', () async {
    SharedPreferences.setMockInitialValues({
      AppearanceKeys.savedSchemeBackgroundPreset: AppBackgroundPreset.custom.index,
      AppearanceKeys.savedSchemeBackgroundCustomColor: 0xFF002FA7,
      AppearanceKeys.savedSchemeAccentColor: 0xFFFF6B18,
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(savedColorSchemeProvider);
    await _waitForPrefs();

    final saved = container.read(savedColorSchemeProvider);
    expect(saved, isNotNull);
    expect(saved!.background.preset, AppBackgroundPreset.custom);
    expect(saved.background.customColor, const Color(0xFF002FA7));
    expect(saved.accentColor, const Color(0xFFFF6B18));
  });

  test('缺键的「我的搭配」按未保存处理', () async {
    SharedPreferences.setMockInitialValues({
      AppearanceKeys.savedSchemeBackgroundPreset: AppBackgroundPreset.oled.index,
      // 故意缺少自定义色与主题色两个键
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(savedColorSchemeProvider);
    await _waitForPrefs();

    expect(container.read(savedColorSchemeProvider), isNull);
  });
}
