import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

/// 断言一套主题里「彩色实心底」的前景达到 AA 正文对比度，且强调色本身不被改写。
void expectThemeForegroundReadable(ThemeData theme) {
  final scheme = theme.colorScheme;

  expect(AppContrast.contrastRatio(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(4.5));

  // 这四处曾经各自写死白色，必须统一跟随 onPrimary
  expect(theme.floatingActionButtonTheme.foregroundColor, scheme.onPrimary);
  expect(theme.elevatedButtonTheme.style!.foregroundColor!.resolve(<WidgetState>{}), scheme.onPrimary);
  expect(theme.switchTheme.thumbColor!.resolve(<WidgetState>{WidgetState.selected}), scheme.onPrimary);
  expect(theme.checkboxTheme.checkColor!.resolve(<WidgetState>{}), scheme.onPrimary);

  // primaryContainer 是半透明淡底，需合到 surface 上再验对比度
  expect(
    AppContrast.contrastRatio(scheme.onPrimaryContainer, Color.alphaBlend(scheme.primaryContainer, scheme.surface)),
    greaterThanOrEqualTo(4.5),
  );

  // 强调色当文字/图标用时：legacy 保持用户所选原色（未注册 AppAccentInk）；
  // 派生背景（OLED/主题色背景/自定义）改用校准过的可读版本，且必须达到正文对比度。
  final accentInk = theme.accentInk;
  expect(theme.bottomNavigationBarTheme.selectedItemColor, accentInk);
  expect(theme.navigationBarTheme.iconTheme!.resolve(<WidgetState>{WidgetState.selected})!.color, accentInk);
  expect(theme.textButtonTheme.style!.foregroundColor!.resolve(<WidgetState>{}), accentInk);
  if (theme.extension<AppAccentInk>() == null) {
    expect(accentInk, scheme.primary);
  } else {
    expect(AppContrast.contrastRatio(accentInk, scheme.surface), greaterThanOrEqualTo(4.5));
    expect(AppContrast.contrastRatio(accentInk, theme.scaffoldBackgroundColor), greaterThanOrEqualTo(4.5));
  }
  expect(theme.radioTheme.fillColor!.resolve(<WidgetState>{WidgetState.selected}), scheme.primary);
}

/// 断言主题里的表面角色与调色板逐项一致。
void expectThemeSurfaces(ThemeData theme, AppSurfacePalette palette) {
  final scheme = theme.colorScheme;

  expect(theme.scaffoldBackgroundColor, palette.canvas);
  expect(theme.brightness, palette.brightness);
  expect(scheme.brightness, palette.brightness);
  expect(scheme.surface, palette.surface);
  expect(scheme.surfaceContainerLowest, palette.surfaceContainerLowest);
  expect(scheme.surfaceContainerLow, palette.surfaceContainerLow);
  expect(scheme.surfaceContainer, palette.surfaceContainer);
  expect(scheme.surfaceContainerHigh, palette.surfaceContainerHigh);
  expect(scheme.surfaceContainerHighest, palette.surfaceContainerHighest);
  expect(scheme.onSurface, palette.onSurface);
  expect(scheme.onSurfaceVariant, palette.onSurfaceVariant);
  expect(scheme.outline, palette.outline);
  expect(scheme.outlineVariant, palette.outlineVariant);
  expect(scheme.inverseSurface, palette.inverseSurface);
  expect(scheme.onInverseSurface, palette.onInverseSurface);

  expect(theme.appBarTheme.backgroundColor, palette.surface);
  expect(theme.cardTheme.color, palette.surface);
  expect(theme.bottomNavigationBarTheme.backgroundColor, palette.surface);
  expect(theme.navigationBarTheme.backgroundColor, palette.surface);
  expect(theme.drawerTheme.backgroundColor, palette.surface);
  expect(theme.dialogTheme.backgroundColor, palette.isDark ? palette.surfaceContainer : palette.surface);
  expect(theme.bottomSheetTheme.backgroundColor, palette.isDark ? palette.surfaceContainerLow : palette.surface);
  expect(theme.popupMenuTheme.color, palette.isDark ? palette.surfaceContainer : palette.surface);
  expect(theme.dividerTheme.color, palette.outlineVariant);
  expect(theme.inputDecorationTheme.fillColor, palette.isDark ? palette.surfaceContainerLow : palette.surface);
}

void main() {
  group('AppTheme 深色浮层表面', () {
    final dark = AppTheme.darkTheme(AppTheme.primaryDefault);
    final darkScheme = dark.colorScheme;

    test('SnackBar 不再使用近白的 inverseSurface', () {
      final snackBar = dark.snackBarTheme;

      expect(snackBar.backgroundColor, darkScheme.surfaceContainerHighest);
      expect(snackBar.backgroundColor!.computeLuminance(), lessThan(0.2));
      // 底色换成深色后，正文必须跟着换；否则默认 onInverseSurface 会变成
      // 深色字压在深色底上。
      expect(snackBar.contentTextStyle?.color, darkScheme.onSurface);
      expect(snackBar.contentTextStyle!.color!.computeLuminance(), greaterThan(0.5));
    });

    test('Tooltip 使用深色抬升表面与浅色文字', () {
      final decoration = dark.tooltipTheme.decoration;

      expect(decoration, isA<BoxDecoration>());
      final box = decoration! as BoxDecoration;
      expect(box.color, darkScheme.surfaceContainerHighest);
      expect(box.color!.computeLuminance(), lessThan(0.2));
      expect(dark.tooltipTheme.textStyle?.color, darkScheme.onSurface);
    });

    test('浅色主题的 SnackBar / Tooltip 保持原样', () {
      final light = AppTheme.lightTheme(AppTheme.primaryDefault);
      final lightScheme = light.colorScheme;

      expect(light.snackBarTheme.backgroundColor, isNull);
      expect((light.tooltipTheme.decoration! as BoxDecoration).color, lightScheme.inverseSurface);
    });
  });

  group('AppTheme 主题色前景对比度', () {
    for (final accent in presetAccentColors) {
      final label = '#${accent.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

      test('$label 浅色主题', () => expectThemeForegroundReadable(AppTheme.lightTheme(accent)));

      test('$label 深色主题', () => expectThemeForegroundReadable(AppTheme.darkTheme(accent)));
    }
  });

  group('AppTheme 可读强调色令牌', () {
    test('同色系主题色背景下注册可读强调色并标记需要描边', () {
      final theme = AppTheme.build(
        accentColor: const Color(0xFFC5E803),
        background: const AppBackgroundSetting(preset: AppBackgroundPreset.accent),
        platformBrightness: Brightness.light,
      );

      expect(theme.accentInk, isNot(theme.colorScheme.primary));
      expect(theme.accentNeedsOutline, isTrue);
      expect(AppContrast.contrastRatio(theme.accentInk, theme.colorScheme.surface), greaterThanOrEqualTo(4.5));
      // 轨迹与滑块这类「表面上的强调色前景」也要可读
      expect(theme.progressIndicatorTheme.color, theme.accentInk);
      expect(theme.sliderTheme.activeTrackColor, theme.accentInk);
    });

    test('legacy 浅色主题不注册令牌，取到的仍是原色', () {
      final theme = AppTheme.lightTheme(AppTheme.primaryDefault);
      expect(theme.extension<AppAccentInk>(), isNull);
      expect(theme.accentInk, theme.colorScheme.primary);
      expect(theme.accentNeedsOutline, isFalse);
    });

    test('撞色搭配（自定义深底 + 亮强调色）时强调色本身已可读，不再改写', () {
      const accent = Color(0xFF3DDC97);
      final theme = AppTheme.build(
        accentColor: accent,
        background: const AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF2B1B4A)),
        platformBrightness: Brightness.light,
      );
      expect(theme.accentInk, theme.colorScheme.primary);
    });
  });

  group('AppTheme legacy 表面保持原值', () {
    test('浅色', () {
      final theme = AppTheme.lightTheme(AppTheme.primaryDefault);
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF9F9FF));
      expect(theme.colorScheme.surface, Colors.white);
      expect(theme.colorScheme.surfaceContainerLow, const Color(0xFFF9F9FF));
      expect(theme.colorScheme.surfaceContainerHighest, const Color(0xFFE4E5EC));
      expect(theme.colorScheme.onSurface, const Color(0xFF191B23));
      expect(theme.colorScheme.primary, AppTheme.primaryDefault);
    });

    test('深色', () {
      final theme = AppTheme.darkTheme(AppTheme.primaryDefault);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF111318));
      expect(theme.colorScheme.surface, const Color(0xFF1A1D24));
      expect(theme.colorScheme.surfaceContainerHighest, const Color(0xFF363A45));
      expect(theme.colorScheme.onSurface, const Color(0xFFE2E2E9));
      expect(theme.colorScheme.primary, AppTheme.primaryDefault);
    });
  });

  group('AppTheme 背景预设', () {
    const customColor = Color(0xFFF2E9DC);

    for (final accent in presetAccentColors) {
      final label = '#${accent.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

      for (final preset in AppBackgroundPreset.values) {
        for (final platformBrightness in Brightness.values) {
          test('$label ${preset.name} ${platformBrightness.name}', () {
            final setting = AppBackgroundSetting(preset: preset, customColor: customColor);
            final palette = setting.resolvePalette(accentColor: accent, platformBrightness: platformBrightness);
            final theme = AppTheme.build(
              accentColor: accent,
              background: setting,
              platformBrightness: platformBrightness,
            );

            expectThemeForegroundReadable(theme);
            expectThemeSurfaces(theme, palette);

            // 画布永远等于用户所选颜色；按钮强调色只在和画布过近时微调
            final primary = resolvePrimaryAccent(accent, palette);
            expect(theme.colorScheme.primary, primary);
            expect(theme.floatingActionButtonTheme.backgroundColor, primary);
            expect(theme.switchTheme.trackColor!.resolve(<WidgetState>{WidgetState.selected}), primary);
            expect(theme.checkboxTheme.fillColor!.resolve(<WidgetState>{WidgetState.selected}), primary);
            if (palette.isLegacy) {
              // legacy 主题保持所选强调色原色，避免默认观感变化
              expect(primary, accent);
            } else {
              // 派生背景下按钮强调色必须能在画布上辨认
              expect(AppContrast.contrastRatio(primary, palette.canvas), greaterThanOrEqualTo(1.18));
            }

            if (!palette.isLegacy) {
              // Flutter 默认文字/图标色不跟随 ColorScheme，派生主题必须显式校准
              expect(theme.textTheme.bodyMedium?.color, palette.onSurface);
              expect(theme.iconTheme.color, palette.onSurface);
            }
          });
        }
      }
    }

    test('自定义色等于主题色时画布不变、按钮微调且仍可读', () {
      const accent = Color(0xFFE91E8C);
      const setting = AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: accent);
      final theme = AppTheme.build(accentColor: accent, background: setting, platformBrightness: Brightness.light);

      // 背景保持用户所选色原样，不再被压暗/提亮
      expect(theme.scaffoldBackgroundColor, accent);
      // 按钮侧微调一档，保证在背景上仍可辨认
      expect(theme.colorScheme.primary, isNot(accent));
      expect(
        AppContrast.contrastRatio(theme.colorScheme.primary, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(1.18),
      );
      expect(theme.elevatedButtonTheme.style?.side?.resolve(<WidgetState>{})?.color, theme.colorScheme.outlineVariant);
      expectThemeForegroundReadable(theme);
    });
  });
}
