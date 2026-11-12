import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

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

  // 强调色当文字/图标时同样保持用户所选原色，不再按背景二次调色
  expect(theme.bottomNavigationBarTheme.selectedItemColor, scheme.primary);
  expect(theme.navigationBarTheme.iconTheme!.resolve(<WidgetState>{WidgetState.selected})!.color, scheme.primary);
  expect(theme.textButtonTheme.style!.foregroundColor!.resolve(<WidgetState>{}), scheme.primary);
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

            // 主题色始终是用户所选原色，不随背景改写
            expect(theme.colorScheme.primary, accent);
            expect(theme.floatingActionButtonTheme.backgroundColor, accent);
            expect(theme.switchTheme.trackColor!.resolve(<WidgetState>{WidgetState.selected}), accent);
            expect(theme.checkboxTheme.fillColor!.resolve(<WidgetState>{WidgetState.selected}), accent);

            if (!palette.isLegacy) {
              // Flutter 默认文字/图标色不跟随 ColorScheme，派生主题必须显式校准
              expect(theme.textTheme.bodyMedium?.color, palette.onSurface);
              expect(theme.iconTheme.color, palette.onSurface);
            }
          });
        }
      }
    }

    test('自定义色等于主题色时自动偏移且仍可读', () {
      const accent = Color(0xFFE91E8C);
      const setting = AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: accent);
      final theme = AppTheme.build(accentColor: accent, background: setting, platformBrightness: Brightness.light);

      expect(theme.scaffoldBackgroundColor, isNot(accent));
      expect(AppContrast.contrastRatio(theme.scaffoldBackgroundColor, accent), greaterThanOrEqualTo(1.3));
      expectThemeForegroundReadable(theme);
    });
  });
}
