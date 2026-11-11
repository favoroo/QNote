import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
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
  });
}
