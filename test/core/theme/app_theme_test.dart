import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

/// 断言一套主题里「彩色实心底」与「强调色当文字」的前景都达到 AA 正文对比度。
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

  // 强调色当文字/图标贴在 surface 上时同样要读得清
  expect(
    AppContrast.contrastRatio(theme.bottomNavigationBarTheme.selectedItemColor!, scheme.surface),
    greaterThanOrEqualTo(4.5),
  );
  expect(
    AppContrast.contrastRatio(
      theme.navigationBarTheme.iconTheme!.resolve(<WidgetState>{WidgetState.selected})!.color!,
      scheme.surface,
    ),
    greaterThanOrEqualTo(4.5),
  );
  expect(
    AppContrast.contrastRatio(theme.textButtonTheme.style!.foregroundColor!.resolve(<WidgetState>{})!, scheme.surface),
    greaterThanOrEqualTo(4.5),
  );
  expect(
    AppContrast.contrastRatio(
      theme.radioTheme.fillColor!.resolve(<WidgetState>{WidgetState.selected})!,
      scheme.surface,
    ),
    greaterThanOrEqualTo(4.5),
  );
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
}
