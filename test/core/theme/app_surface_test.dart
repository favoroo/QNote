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

    test('浅色表面保住画布色相，且只比画布亮一丝', () {
      // 历史问题：直接叠 55% 白会把饱和的黄绿 #B3CB41 冲成米黄 #DDE8AA，
      // 用户会觉得「卡片和我选的颜色不是一回事」。现在统一按目标对比度 1.12
      // 提亮（与纯黑画布 #000000 -> #121212 同档），色相不变。
      const canvases = <Color>[
        Color(0xFFB3CB41), // 黄绿
        Color(0xFFBCD7EE), // 雾蓝
        Color(0xFFDCCBF2), // 香芋紫
        Color(0xFFE0C6AE), // 奶茶
        Color(0xFFC5E803), // 荧光黄绿
      ];

      for (final canvas in canvases) {
        final palette = AppSurfacePalette.derived(canvas);
        expect(palette.brightness, Brightness.light);

        final canvasHsl = HSLColor.fromColor(canvas);
        final surfaceHsl = HSLColor.fromColor(palette.surface);
        // 色相基本不动（容差 2°），只允许明度抬升
        final hueGap = (surfaceHsl.hue - canvasHsl.hue).abs();
        expect(
          hueGap < 2 || hueGap > 358,
          isTrue,
          reason: '${_hex(canvas)} 的表面色相从 ${canvasHsl.hue} 漂到了 ${surfaceHsl.hue}',
        );
        expect(surfaceHsl.lightness, greaterThan(canvasHsl.lightness));
        // 和纯黑画布同档：只差 1.12 左右，卡片和画布始终是同一色系
        expect(AppContrast.contrastRatio(palette.surface, palette.canvas), greaterThan(1.09));
        expect(AppContrast.contrastRatio(palette.surface, palette.canvas), lessThan(1.16));
      }
    });

    test('主题色背景的表面色与纯黑/纯白预设同档', () {
      // 用户反馈：主题色背景时上下栏和画布色差太大，像换了个颜色。
      // 现在统一按 1.12 目标对比度推导，接近纯黑画布（#000 -> #121212）的观感。
      const accents = <Color>[
        Color(0xFF005BCB),
        Color(0xFFC5E803),
        Color(0xFFE91E8C),
        Color(0xFF00E676),
        Color(0xFFFF9500),
      ];

      for (final accent in accents) {
        const setting = AppBackgroundSetting(preset: AppBackgroundPreset.accent);
        final palette = setting.resolvePalette(accentColor: accent, platformBrightness: Brightness.light);

        final ratio = AppContrast.contrastRatio(palette.canvas, palette.surface);
        expect(ratio, greaterThan(1.09), reason: '${_hex(accent)} 的表面色与画布差太大');
        expect(ratio, lessThan(1.16), reason: '${_hex(accent)} 的表面色与画布几乎没区别');
        // 表面色仍必须和「强调色」本身拉开，否则按钮/图标会融进背景
        expect(AppContrast.contrastRatio(palette.surface, accent), greaterThan(1.1));
      }
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

    test('主题色背景的请求色就是强调色本身', () {
      // 画布不做任何压暗/提亮：用户选了什么色，页面底色就是什么色。
      for (final accentColor in presetAccentColors) {
        const setting = AppBackgroundSetting(preset: AppBackgroundPreset.accent);
        final canvas = setting.resolveCanvas(accentColor: accentColor, platformBrightness: Brightness.light);
        expect(canvas.toARGB32(), accentColor.toARGB32());
      }
    });

    test('按钮强调色在主题色背景上仍保持 1.18 同色系对比度', () {
      for (final accentColor in presetAccentColors) {
        const setting = AppBackgroundSetting(preset: AppBackgroundPreset.accent);
        final palette = setting.resolvePalette(accentColor: accentColor, platformBrightness: Brightness.light);
        final primary = resolvePrimaryAccent(accentColor, palette);
        expect(
          AppContrast.contrastRatio(primary, palette.canvas),
          greaterThanOrEqualTo(1.18),
          reason: '${_hex(accentColor)} 的按钮强调色融进了画布',
        );
      }
    });

    test('自定义色等于强调色时画布保持原色，改由按钮微调', () {
      const accentColor = Color(0xFFE91E8C);
      const setting = AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: accentColor);
      final palette = setting.resolvePalette(accentColor: accentColor, platformBrightness: Brightness.light);
      expect(palette.canvas.toARGB32(), accentColor.toARGB32());

      final primary = resolvePrimaryAccent(accentColor, palette);
      expect(primary.toARGB32(), isNot(accentColor.toARGB32()));
      expect(AppContrast.contrastRatio(primary, palette.canvas), greaterThanOrEqualTo(1.18));
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

    test('新增的纯色背景有固定画布且明暗推导正确', () {
      const cases = {
        AppBackgroundPreset.paper: (0xFFF3E8D8, Brightness.light),
        AppBackgroundPreset.mist: (0xFFD6E4F0, Brightness.light),
        AppBackgroundPreset.pine: (0xFF0E2A22, Brightness.dark),
      };
      cases.forEach((preset, expected) {
        final setting = AppBackgroundSetting(preset: preset);
        // 固定画布不受强调色与系统亮度影响
        expect(
          setting.resolveCanvas(accentColor: accent, platformBrightness: Brightness.light).toARGB32(),
          expected.$1,
          reason: '$preset 的画布色应固定',
        );
        expect(
          setting.resolvePalette(accentColor: accent, platformBrightness: Brightness.light).brightness,
          expected.$2,
          reason: '$preset 的明暗应由画布推导',
        );
        // 派生背景要走按钮避让，强调色与画布过近时会被推开
        final palette = setting.resolvePalette(accentColor: accent, platformBrightness: Brightness.light);
        expect(palette.isLegacy, isFalse);
      });
    });

    test('背景展示顺序覆盖全部预设且「自定义」留在最后一格', () {
      expect(backgroundPresetDisplayOrder.toSet(), AppBackgroundPreset.values.toSet());
      expect(backgroundPresetDisplayOrder.length, AppBackgroundPreset.values.length);
      expect(backgroundPresetDisplayOrder.last, AppBackgroundPreset.custom);
    });
  });

  group('ensureAccentGap', () {
    test('全部预设强调色都能拉到 1.18 以上且沿同色系提亮不混黑变脏', () {
      for (final accentColor in presetAccentColors) {
        final adjusted = ensureAccentGap(accentColor, accentColor);
        expect(AppContrast.contrastRatio(adjusted, accentColor), greaterThanOrEqualTo(1.18));
        // 优先往亮端抬升，亮色主题色（如荧光黄绿、春天亮绿）不再被拉暗成浑浊橄榄色
        expect(
          adjusted.computeLuminance(),
          greaterThan(accentColor.computeLuminance()),
          reason: '${_hex(accentColor)} 不应朝黑压暗',
        );
      }
    });

    test('接近纯白时亮端余量不足会回落到同色系压暗', () {
      const nearWhite = Color(0xFFFFFFFF);
      final adjusted = ensureAccentGap(nearWhite, nearWhite);
      expect(AppContrast.contrastRatio(adjusted, nearWhite), greaterThanOrEqualTo(1.18));
      expect(adjusted.computeLuminance(), lessThan(nearWhite.computeLuminance()));
    });

    test('已经足够远时原样返回', () {
      const background = Color(0xFFF9F9FF);
      const accentColor = Color(0xFF005BCB);
      expect(ensureAccentGap(background, accentColor), background);
    });
  });
}
