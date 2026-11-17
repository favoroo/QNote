import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/health_colors.dart';

/// 健康语义色的验收口径：
/// - 作为图标 / 进度条 / 分段条填充时，只需 WCAG 1.4.11 的图形级 3:1；
/// - 作为文字（睡眠时长、指标数值、徽标、收支金额）时，界面层统一走
///   `AppContrast.readable` / `inkOnTint` 压深，这里验证压深后确实达标。
void main() {
  group('HealthColors 等级色阶', () {
    const lightSurface = Colors.white;
    const darkSurface = Color(0xFF1A1D24);

    test('五档等级色在各自底色上都达到图形级对比度', () {
      for (final brightness in Brightness.values) {
        final background = brightness == Brightness.dark ? darkSurface : lightSurface;
        final levels = <String, Color>{
          'good': HealthColors.levelGood(brightness),
          'info': HealthColors.levelInfo(brightness),
          'warn': HealthColors.levelWarn(brightness),
          'alert': HealthColors.levelAlert(brightness),
          'critical': HealthColors.critical(brightness),
          'neutral': HealthColors.neutral(brightness),
        };
        for (final entry in levels.entries) {
          expect(
            AppContrast.contrastRatio(entry.value, background),
            greaterThanOrEqualTo(AppContrast.minimumGraphicRatio),
            reason: '$brightness 下等级色「${entry.key}」作图形不可读',
          );
        }
      }
    });

    test('等级色作文字时，经 readable 压深后达到正文级对比度', () {
      for (final brightness in Brightness.values) {
        final background = brightness == Brightness.dark ? darkSurface : lightSurface;
        final levels = [
          HealthColors.levelGood(brightness),
          HealthColors.levelInfo(brightness),
          HealthColors.levelWarn(brightness),
          HealthColors.levelAlert(brightness),
          HealthColors.critical(brightness),
          HealthColors.neutral(brightness),
        ];
        for (final color in levels) {
          final ink = AppContrast.readable(color, background);
          expect(
            AppContrast.contrastRatio(ink, background),
            greaterThanOrEqualTo(AppContrast.minimumTextRatio),
            reason: '$brightness 下 #${color.toARGB32().toRadixString(16)} 压深后仍不可读',
          );
        }
      }
    });

    test('等级色作徽标文字时，经 inkOnTint 压深后达到正文级对比度', () {
      // 徽标形态：同色 12~15% 淡底 + 同色文字
      for (final brightness in Brightness.values) {
        final background = brightness == Brightness.dark ? darkSurface : lightSurface;
        for (final alpha in [0.1, 0.12, 0.14, 0.15]) {
          final levels = [
            HealthColors.levelGood(brightness),
            HealthColors.levelWarn(brightness),
            HealthColors.levelAlert(brightness),
            HealthColors.critical(brightness),
          ];
          for (final color in levels) {
            final ink = AppContrast.inkOnTint(color, background, alpha);
            final tint = Color.alphaBlend(color.withValues(alpha: alpha), background);
            expect(
              AppContrast.contrastRatio(ink, tint),
              greaterThanOrEqualTo(AppContrast.minimumTextRatio),
              reason: '$brightness 下 alpha=$alpha 的徽标文字不可读',
            );
          }
        }
      }
    });
  });

  group('HealthColors 睡眠分期', () {
    test('四段分期色互不相同，且作填充时达到图形级对比度', () {
      for (final brightness in Brightness.values) {
        final background = brightness == Brightness.dark ? const Color(0xFF1A1D24) : Colors.white;
        final stages = {
          HealthColors.deepSleep(brightness).toARGB32(),
          HealthColors.lightSleep(brightness).toARGB32(),
          HealthColors.remSleep(brightness).toARGB32(),
          HealthColors.awake(brightness).toARGB32(),
        };
        expect(stages.length, 4, reason: '$brightness 下睡眠分期存在撞色');
        for (final argb in stages) {
          final color = Color(argb);
          expect(
            AppContrast.contrastRatio(color, background),
            greaterThanOrEqualTo(AppContrast.minimumGraphicRatio),
            reason: '$brightness 下分期色 #${argb.toRadixString(16)} 作分段条不可读',
          );
        }
      }
    });
  });
}
