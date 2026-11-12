import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/appearance_bootstrap.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveBackgroundSetting', () {
    test('有 background_preset 时直接采用，忽略旧 theme_mode', () {
      final setting = resolveBackgroundSetting(
        presetIndex: AppBackgroundPreset.oled.index,
        customColorValue: 0xFF336699,
        legacyThemeMode: 1,
      );
      expect(setting.preset, AppBackgroundPreset.oled);
      expect(setting.customColor, const Color(0xFF336699));
    });

    test('没有 background_preset 时按旧 theme_mode 迁移', () {
      expect(
        resolveBackgroundSetting(presetIndex: null, customColorValue: null, legacyThemeMode: 2).preset,
        AppBackgroundPreset.dark,
      );
      expect(
        resolveBackgroundSetting(presetIndex: null, customColorValue: null, legacyThemeMode: 1).preset,
        AppBackgroundPreset.light,
      );
      expect(
        resolveBackgroundSetting(presetIndex: null, customColorValue: null, legacyThemeMode: null).preset,
        AppBackgroundPreset.system,
      );
    });

    test('索引越界时夹到合法区间而不是抛异常', () {
      final setting = resolveBackgroundSetting(presetIndex: 99, customColorValue: null, legacyThemeMode: null);
      expect(setting.preset, AppBackgroundPreset.values.last);
    });
  });

  group('AppearanceBootstrap 预热', () {
    tearDown(AppearanceBootstrap.resetForTest);

    test('预热后首帧直接拿到用户保存的浅色背景（系统深色下不再闪深色）', () async {
      // 模拟用户场景：手机深色模式，但 App 里选的是浅色背景
      SharedPreferences.setMockInitialValues({
        AppearanceKeys.backgroundPreset: AppBackgroundPreset.light.index,
        AppearanceKeys.accentColor: 0xFFE91E8C,
      });

      await AppearanceBootstrap.warmUp();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 首次 read 就是终态，不存在「先 system 再切 light」的中间态
      expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.light);
      expect(container.read(accentColorProvider), const Color(0xFFE91E8C));
    });

    test('未预热时 Provider 回落到异步加载，行为与旧版一致', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.backgroundPreset: AppBackgroundPreset.dark.index});

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 首次构建是默认值
      expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.system);
      // 异步加载完成后切到持久化值
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(backgroundSettingProvider).preset, AppBackgroundPreset.dark);
    });

    test('预热会写出原生启动屏所需的两个画布色与明暗标记', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.backgroundPreset: AppBackgroundPreset.light.index});

      await AppearanceBootstrap.warmUp();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppearanceKeys.launchCanvasLight), '#F9F9FF');
      expect(prefs.getString(AppearanceKeys.launchCanvasDark), '#F9F9FF');
      // 固定浅色背景 → 启动屏强制浅色，不再跟随系统深色
      expect(prefs.getInt(AppearanceKeys.launchNightMode), 0);
    });

    test('跟随系统时明暗标记交还给系统（-1）', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.backgroundPreset: AppBackgroundPreset.system.index});

      await AppearanceBootstrap.warmUp();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(AppearanceKeys.launchNightMode), -1);
    });

    test('OLED 背景的启动色为纯黑且强制深色', () async {
      SharedPreferences.setMockInitialValues({AppearanceKeys.backgroundPreset: AppBackgroundPreset.oled.index});

      await AppearanceBootstrap.warmUp();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppearanceKeys.launchCanvasLight), '#000000');
      expect(prefs.getString(AppearanceKeys.launchCanvasDark), '#000000');
      expect(prefs.getInt(AppearanceKeys.launchNightMode), 1);
    });
  });
}
