import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/providers/theme_provider.dart';

void main() {
  group('AppContrast.contrastRatio', () {
    test('黑白为对比度极值', () {
      expect(AppContrast.contrastRatio(Colors.black, Colors.white), closeTo(21.0, 0.01));
      expect(AppContrast.contrastRatio(Colors.white, Colors.white), closeTo(1.0, 0.01));
    });
  });

  group('AppContrast.onColor', () {
    test('全部预设主题色都能取到达标的黑/白前景', () {
      for (final accent in presetAccentColors) {
        final foreground = AppContrast.onColor(accent);
        expect(foreground, anyOf(Colors.black, Colors.white));
        expect(
          AppContrast.contrastRatio(foreground, accent),
          greaterThanOrEqualTo(AppContrast.minimumTextRatio),
          reason: '主题色 #${accent.toARGB32().toRadixString(16)} 的自动前景色对比度不足',
        );
      }
    });

    test('深色取白字、亮色取黑字', () {
      expect(AppContrast.onColor(const Color(0xFF005BCB)), Colors.white);
      expect(AppContrast.onColor(const Color(0xFFC5E803)), Colors.black);
    });

    test('中间亮度色严格取对比度更高的一侧', () {
      // 活力红：白字 3.55:1 < 黑字 5.92:1
      expect(AppContrast.onColor(const Color(0xFFFF3B30)), Colors.black);
      // 典雅紫：白字 4.81:1 > 黑字 4.36:1
      expect(AppContrast.onColor(const Color(0xFF7C4DFF)), Colors.white);
    });
  });

  group('AppContrast.inkOnTint', () {
    test('内容色贴同色淡底后仍能达标，并保留色相', () {
      const amber = Color(0xFFF59E0B);
      final ink = AppContrast.inkOnTint(amber, Colors.white, 0.1);
      final tint = Color.alphaBlend(amber.withValues(alpha: 0.1), Colors.white);

      expect(ink, isNot(amber));
      expect(AppContrast.contrastRatio(ink, tint), greaterThanOrEqualTo(AppContrast.minimumTextRatio));
      // 琥珀压深后仍是暖色：红通道高于蓝通道
      expect(ink.r, greaterThan(ink.b));
    });

    test('已达标的内容色原样返回', () {
      // 深蓝在自身 10% 淡底上约 5.7:1，无需调整
      const deepBlue = Color(0xFF1D4ED8);
      final ink = AppContrast.inkOnTint(deepBlue, Colors.white, 0.1);

      expect(ink, deepBlue);
    });

    test('全部标签色在浅深两种底色上都能读出前景', () {
      for (final color in TagColors.map.values) {
        for (final background in [Colors.white, const Color(0xFF1A1D24)]) {
          final ink = AppContrast.inkOnTint(color, background, 0.1);
          final tint = Color.alphaBlend(color.withValues(alpha: 0.1), background);
          expect(
            AppContrast.contrastRatio(ink, tint),
            greaterThanOrEqualTo(AppContrast.minimumTextRatio),
            reason: '标签色 #${color.toARGB32().toRadixString(16)} 在 $background 上不可读',
          );
        }
      }
    });
  });

  group('AppContrast.readable', () {
    test('已达标时原样返回', () {
      const blue = Color(0xFF005BCB);
      expect(AppContrast.readable(blue, Colors.white), blue);
    });

    test('浅色强调色在白底上被压深到达标，且保留色相', () {
      const neonGreen = Color(0xFFC5E803);
      final adjusted = AppContrast.readable(neonGreen, Colors.white);

      expect(adjusted, isNot(neonGreen));
      expect(AppContrast.contrastRatio(adjusted, Colors.white), greaterThanOrEqualTo(4.5));
      // 原色相是黄绿，压深后绿通道仍应高于蓝通道
      expect(adjusted.g, greaterThan(adjusted.b));
    });

    test('深色强调色在深底上被提亮到达标', () {
      const darkSurface = Color(0xFF1A1D24);
      const blue = Color(0xFF005BCB);
      final adjusted = AppContrast.readable(blue, darkSurface);

      expect(adjusted, isNot(blue));
      expect(AppContrast.contrastRatio(adjusted, darkSurface), greaterThanOrEqualTo(4.5));
    });

    test('中间亮度背景也能同时尝试黑白两侧并达标', () {
      const midTones = [Color(0xFF808080), Color(0xFF767676), Color(0xFF6E6E6E)];
      const colors = [Color(0xFF005BCB), Color(0xFFC5E803), Color(0xFFE91E8C), Color(0xFF7C4DFF)];
      for (final background in midTones) {
        for (final color in colors) {
          final adjusted = AppContrast.readable(color, background);
          expect(
            AppContrast.contrastRatio(adjusted, background),
            greaterThanOrEqualTo(4.5),
            reason: '$color 在 $background 上不可读',
          );
        }
      }
    });
  });
}
