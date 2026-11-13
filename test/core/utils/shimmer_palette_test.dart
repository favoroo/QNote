import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/shimmer_palette.dart';

void main() {
  // 覆盖内置推荐搭配里明度差异较大的几档主题色，避免只在默认蓝上成立。
  const primaries = <Color>[
    Color(0xFFF80004), // 赤焰黑（高饱和红）
    Color(0xFF00E5FF), // 霓虹青
    Color(0xFF7C4DFF), // 午夜紫
    Color(0xFFFFB300), // 深海金
    Color(0xFF005BCB), // 晴空蓝
  ];

  group('buildShimmerPalette', () {
    test('颜色与断点等长、断点单调递增、首尾同色（旋转接缝不跳变）', () {
      for (final brightness in Brightness.values) {
        final palette = buildShimmerPalette(primary: const Color(0xFF005BCB), brightness: brightness);

        expect(palette.colors.length, palette.stops.length);
        expect(palette.stops.first, 0);
        expect(palette.stops.last, 1);
        for (var i = 1; i < palette.stops.length; i++) {
          expect(palette.stops[i], greaterThan(palette.stops[i - 1]));
        }
        expect(palette.colors.first, palette.colors.last);
      }
    });

    test('深色高光保持主题色相，不会退化成白光', () {
      for (final primary in primaries) {
        final palette = buildShimmerPalette(primary: primary, brightness: Brightness.dark);
        final head = palette.colors.reduce((a, b) => _glowScore(a) >= _glowScore(b) ? a : b);
        final headHsl = HSLColor.fromColor(head);
        final primaryHsl = HSLColor.fromColor(primary);

        // 高光允许比主题色更淡，但色相必须还在同一族里（RGB 向白插值只有几度偏移）。
        expect(_hueDistance(headHsl.hue, primaryHsl.hue), lessThan(8), reason: 'primary=$primary head=$head');
        expect(headHsl.saturation, greaterThan(0.3), reason: '深色高光被掺成白色：primary=$primary');
        expect(head.a, lessThan(1), reason: '高光透明度应留出柔和余量');
      }
    });

    test('轨道保持低透明度：提取中的卡片不能像被描了一圈实线', () {
      final dark = buildShimmerPalette(primary: const Color(0xFF005BCB), brightness: Brightness.dark);
      final light = buildShimmerPalette(primary: const Color(0xFF005BCB), brightness: Brightness.light);

      expect(dark.colors.first.a, 0.12);
      expect(light.colors.first.a, 0.08);
      expect(dark.colors.first.a, lessThan(0.15));
    });
  });
}

/// 视亮度 × alpha：挑出实际看起来最亮的那个断点。
double _glowScore(Color color) => color.computeLuminance() * color.a;

/// 色相最短环形距离（0° 与 360° 视为同一点）。
double _hueDistance(double a, double b) {
  final distance = (a - b).abs() % 360;
  return distance > 180 ? 360 - distance : distance;
}
