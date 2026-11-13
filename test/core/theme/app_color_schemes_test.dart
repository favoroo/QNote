import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_color_schemes.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';

void main() {
  group('推荐搭配', () {
    test('名称唯一且非空', () {
      final names = recommendedColorSchemes.map((scheme) => scheme.name).toList();
      expect(names.toSet().length, names.length);
      expect(names.every((name) => name.trim().isNotEmpty), isTrue);
    });

    test('画布与主题色保持可区分，按钮文字达到 AA', () {
      for (final scheme in recommendedColorSchemes) {
        for (final brightness in Brightness.values) {
          final canvas = scheme.background.resolveCanvas(
            accentColor: scheme.accentColor,
            platformBrightness: brightness,
          );
          expect(
            AppContrast.contrastRatio(canvas, scheme.accentColor),
            greaterThanOrEqualTo(1.3),
            reason: '${scheme.name} 在 $brightness 下画布与主题色过近',
          );
        }
        expect(
          AppContrast.contrastRatio(AppContrast.onColor(scheme.accentColor), scheme.accentColor),
          greaterThanOrEqualTo(AppContrast.minimumTextRatio),
          reason: '${scheme.name} 的主题色上文字对比度不足',
        );
      }
    });

    test('matches 忽略非自定义预设的自定义色', () {
      // 预设分支用独立组合覆盖；自定义分支显式取一套自定义背景，
      // 避免内置列表首套改成浅色预设后用例失去意义
      const presetScheme = AppColorSchemePreset(
        name: '预设测试',
        background: AppBackgroundSetting(preset: AppBackgroundPreset.dark),
        accentColor: Color(0xFF7C4DFF),
      );

      expect(
        presetScheme.matches(
          background: const AppBackgroundSetting(preset: AppBackgroundPreset.dark, customColor: Color(0xFF123456)),
          accentColor: presetScheme.accentColor,
        ),
        isTrue,
      );
      expect(
        presetScheme.matches(
          background: const AppBackgroundSetting(preset: AppBackgroundPreset.light),
          accentColor: presetScheme.accentColor,
        ),
        isFalse,
      );
      expect(
        presetScheme.matches(
          background: const AppBackgroundSetting(preset: AppBackgroundPreset.dark),
          accentColor: const Color(0xFF123456),
        ),
        isFalse,
      );

      final customScheme = recommendedColorSchemes.firstWhere(
        (scheme) => scheme.background.preset == AppBackgroundPreset.custom,
      );
      expect(
        customScheme.matches(
          background: const AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF123456)),
          accentColor: customScheme.accentColor,
        ),
        isFalse,
      );
      expect(customScheme.matches(background: customScheme.background, accentColor: customScheme.accentColor), isTrue);
    });

    test('resolveBackground 保留用户已有自定义色', () {
      const current = AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF123456));
      const presetScheme = AppColorSchemePreset(
        name: '预设测试',
        background: AppBackgroundSetting(preset: AppBackgroundPreset.dark),
        accentColor: Color(0xFF7C4DFF),
      );
      final customScheme = recommendedColorSchemes.firstWhere(
        (scheme) => scheme.background.preset == AppBackgroundPreset.custom,
      );

      expect(presetScheme.resolveBackground(current).preset, AppBackgroundPreset.dark);
      expect(presetScheme.resolveBackground(current).customColor, const Color(0xFF123456));
      expect(customScheme.resolveBackground(current).customColor, customScheme.background.customColor);
    });
  });
}
