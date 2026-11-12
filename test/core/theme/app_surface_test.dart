import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

String _hex(Color color) => '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

void main() {
  group('AppSurfacePalette.derived', () {
    const canvases = <Color>[
      Color(0xFF000000), // OLED
      Color(0xFF111318), // 既有深色背景
      Color(0xFFF9F9FF), // 既有浅色背景
      Color(0xFFFFFFFF), // 纯白
      Color(0xFF808080), // 中间灰
      Color(0xFF767676), // 黑白对比度临界点附近
      Color(0xFFE91E8C), // 玫瑰粉红
      Color(0xFFC5E803), // 荧光黄绿
      Color(0xFF005BCB), // 经典蓝
      Color(0xFF4A148C), // 深紫
      Color(0xFFF2E9DC), // 自定义暖纸色
    ];

    for (final canvas in canvases) {
      test('${_hex(canvas)} 的正文/次级文字在所有表面上都达标', () {
        final palette = AppSurfacePalette.derived(canvas);
        final backgrounds = <Color>[
          palette.canvas,
          palette.surface,
          palette.surfaceContainerLowest,
          palette.surfaceContainerLow,
          palette.surfaceContainer,
          palette.surfaceContainerHigh,
          palette.surfaceContainerHighest,
        ];

        for (final background in backgrounds) {
          expect(
            AppContrast.contrastRatio(palette.onSurface, background),
            greaterThanOrEqualTo(AppContrast.minimumTextRatio),
            reason: '${_hex(canvas)} 的 onSurface 在 ${_hex(background)} 上不可读',
          );
          expect(
            AppContrast.contrastRatio(palette.onSurfaceVariant, background),
            greaterThanOrEqualTo(AppContrast.minimumTextRatio),
            reason: '${_hex(canvas)} 的 onSurfaceVariant 在 ${_hex(background)} 上不可读',
          );
        }

        final expectedBrightness = AppContrast.onColor(canvas) == AppContrast.lightInk
            ? Brightness.dark
            : Brightness.light;
        expect(palette.brightness, expectedBrightness);
      });
    }

    test('OLED 纯黑画布保持纯黑并走深色分支', () {
      final palette = AppSurfacePalette.derived(Colors.black);
      expect(palette.canvas, Colors.black);
      expect(palette.brightness, Brightness.dark);
      expect(palette.surface, isNot(Colors.black));
      expect(AppContrast.contrastRatio(palette.onSurface, palette.surface), greaterThanOrEqualTo(4.5));
    });

    test('纯白画布走浅色分支，卡片与画布可区分', () {
      final palette = AppSurfacePalette.derived(Colors.white);
      expect(palette.brightness, Brightness.light);
      // 正文是带一点点画布色的深墨，不是生硬的纯黑
      expect(palette.onSurface.computeLuminance(), lessThan(0.05));
      expect(palette.surfaceContainerHighest, isNot(Colors.white));
    });
  });

  group('AppBackgroundSetting', () {
    const accent = Color(0xFF005BCB);

    test('跟随系统按平台亮度返回既有浅/深色画布', () {
      const setting = AppBackgroundSetting();
      expect(
        setting.resolveCanvas(accentColor: accent, platformBrightness: Brightness.light),
        AppSurfacePalette.legacyLight.canvas,
      );
      expect(
        setting.resolveCanvas(accentColor: accent, platformBrightness: Brightness.dark),
        AppSurfacePalette.legacyDark.canvas,
      );
      expect(setting.resolvePalette(accentColor: accent, platformBrightness: Brightness.dark).isLegacy, isTrue);
    });

    test('固定浅色/深色不受平台亮度影响', () {
      const light = AppBackgroundSetting(preset: AppBackgroundPreset.light);
      const dark = AppBackgroundSetting(preset: AppBackgroundPreset.dark);
      expect(
        light.resolveCanvas(accentColor: accent, platformBrightness: Brightness.dark),
        AppSurfacePalette.legacyLight.canvas,
      );
      expect(
        dark.resolveCanvas(accentColor: accent, platformBrightness: Brightness.light),
        AppSurfacePalette.legacyDark.canvas,
      );
    });

    test('主题色背景与强调色至少保持 1.3 对比度', () {
      for (final accentColor in presetAccentColors) {
        const setting = AppBackgroundSetting(preset: AppBackgroundPreset.accent);
        final canvas = setting.resolveCanvas(accentColor: accentColor, platformBrightness: Brightness.light);
        expect(
          AppContrast.contrastRatio(canvas, accentColor),
          greaterThanOrEqualTo(1.3),
          reason: '${_hex(accentColor)} 的主题色背景与强调色过近',
        );
        expect(canvas.toARGB32(), isNot(accentColor.toARGB32()));
      }
    });

    test('自定义色等于强调色时自动偏移', () {
      const accentColor = Color(0xFFE91E8C);
      const setting = AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: accentColor);
      final canvas = setting.resolveCanvas(accentColor: accentColor, platformBrightness: Brightness.light);
      expect(canvas.toARGB32(), isNot(accentColor.toARGB32()));
      expect(AppContrast.contrastRatio(canvas, accentColor), greaterThanOrEqualTo(1.3));
    });

    test('自定义色离强调色足够远时保持原色', () {
      const customColor = Color(0xFFF2E9DC);
      const setting = AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: customColor);
      final canvas = setting.resolveCanvas(accentColor: accent, platformBrightness: Brightness.light);
      expect(canvas, customColor);
    });

    test('OLED 预设返回纯黑画布', () {
      const setting = AppBackgroundSetting(preset: AppBackgroundPreset.oled);
      expect(setting.resolveCanvas(accentColor: accent, platformBrightness: Brightness.light), Colors.black);
      final palette = setting.resolvePalette(accentColor: accent, platformBrightness: Brightness.light);
      expect(palette.brightness, Brightness.dark);
      expect(palette.canvas, Colors.black);
    });

    test('旧 theme_mode 兼容索引', () {
      expect(const AppBackgroundSetting().legacyThemeModeIndex(accentColor: accent), 0);
      expect(
        const AppBackgroundSetting(preset: AppBackgroundPreset.light).legacyThemeModeIndex(accentColor: accent),
        1,
      );
      expect(const AppBackgroundSetting(preset: AppBackgroundPreset.dark).legacyThemeModeIndex(accentColor: accent), 2);
      expect(const AppBackgroundSetting(preset: AppBackgroundPreset.oled).legacyThemeModeIndex(accentColor: accent), 2);
    });
  });

  group('ensureAccentGap', () {
    test('全部预设强调色都能拉到 1.3 以上', () {
      for (final accentColor in presetAccentColors) {
        final adjusted = ensureAccentGap(accentColor, accentColor);
        expect(AppContrast.contrastRatio(adjusted, accentColor), greaterThanOrEqualTo(1.3));
      }
    });

    test('已经足够远时原样返回', () {
      const background = Color(0xFFF9F9FF);
      const accentColor = Color(0xFF005BCB);
      expect(ensureAccentGap(background, accentColor), background);
    });
  });
}
