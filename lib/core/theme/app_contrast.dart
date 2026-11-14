import 'package:flutter/material.dart';

/// 前景色对比度工具：按背景色自动选择可读的文字/图标颜色。
///
/// App 的主题色由用户自选，预设里包含 `#C5E803` 荧光黄绿、`#00E676` 春天亮绿这类
/// 极亮色；若前景色写死为白色，浅色主题下按钮、开关、标签胶囊上的文字会失去对比度。
/// 这里统一用 WCAG 相对亮度（[Color.computeLuminance]）做决策，任意主题色都能保持可读。
abstract class AppContrast {
  /// 深色前景。
  ///
  /// 这里取纯黑而非 [ColorScheme.onSurface] 的深中性色 `#191B23`：实测深中性色在
  /// 玫瑰粉红 `#E91E8C` 上只能到 4.15:1（反而不如白字的 4.18:1），纯黑可达 5.03:1，
  /// 8 个预设主题色才全部达到 AA 的 4.5:1。
  static const Color darkInk = Color(0xFF000000);

  /// 浅色前景。
  static const Color lightInk = Color(0xFFFFFFFF);

  /// 正文的 AA 对比度下限。
  static const double minimumTextRatio = 4.5;

  /// 在 [background] 上取黑白中对比度更高的一侧作为前景色。
  ///
  /// 与「亮度超过某个阈值就取黑」等价，但直接比较对比度可避免阈值漂移，也能在两色
  /// 都不达标时仍选相对更可读的那个。
  static Color onColor(Color background) =>
      contrastRatio(darkInk, background) >= contrastRatio(lightInk, background) ? darkInk : lightInk;

  /// 把 [color] 调整为在 [background] 上达到 [minRatio] 对比度的同色系颜色。
  ///
  /// 同时尝试朝黑、朝白两个方向逼近，并按「最小调整步数」返回首个达标色：
  /// 背景偏亮时通常朝黑压、偏暗时朝白提；中间亮度背景也不会只押一个方向而错过
  /// 另一侧可达标的颜色。已达标时原样返回。
  static Color readable(Color color, Color background, {double minRatio = minimumTextRatio}) {
    if (contrastRatio(color, background) >= minRatio) {
      return color;
    }
    const step = 0.02;
    for (var t = step; t <= 1.0; t += step) {
      Color? bestAtStep;
      var bestRatio = 0.0;
      // 同一步长下比较两侧，优先保留对比度更高的候选，避免为了达标而选到更易读性差的
      for (final target in const [darkInk, lightInk]) {
        final candidate = Color.lerp(color, target, t)!;
        final ratio = contrastRatio(candidate, background);
        if (ratio >= minRatio && ratio > bestRatio) {
          bestAtStep = candidate;
          bestRatio = ratio;
        }
      }
      if (bestAtStep != null) {
        return bestAtStep;
      }
    }
    // 理论上黑白总有一侧能达标，这里只是兜底
    return onColor(background);
  }

  /// 让 [color] 同时对一组 [backgrounds] 都达到 [minRatio] 对比度。
  ///
  /// 用途是「主题色当字色/图标/细线」这类会落到多个表面上的前景：同一支强调色可能
  /// 同时画在画布与卡片上，只对其中一个校准，另一个就可能不达标。这里逐级朝黑/朝白
  /// 试探，取第一个「全部背景都达标」的颜色；已全部达标时原样返回。
  static Color inkFor(Color color, List<Color> backgrounds, {double minRatio = minimumTextRatio}) {
    if (backgrounds.every((background) => contrastRatio(color, background) >= minRatio)) {
      return color;
    }
    const step = 0.02;
    for (var t = step; t <= 1.0; t += step) {
      for (final target in const [darkInk, lightInk]) {
        final candidate = Color.lerp(color, target, t)!;
        if (backgrounds.every((background) => contrastRatio(candidate, background) >= minRatio)) {
          return candidate;
        }
      }
    }
    // 兜底：对最不利的那块背景取黑/白中更可读的一侧
    final worst = backgrounds.reduce((a, b) => contrastRatio(color, a) <= contrastRatio(color, b) ? a : b);
    return onColor(worst);
  }

  /// 内容色贴在自身 [tintAlpha] 透明度的淡底上时的可读前景。
  ///
  /// 标签色/健康数据色这类内容色常以「同色淡底 + 同色文字/图标」出现，而琥珀、
  /// 翡翠绿、天蓝等亮色系在浅底上只有 2~3:1；这里先合成真实底色再压深，保留色相
  /// 的同时把对比度拉到 [minRatio]。
  static Color inkOnTint(Color color, Color background, double tintAlpha, {double minRatio = minimumTextRatio}) =>
      readable(color, Color.alphaBlend(color.withValues(alpha: tintAlpha), background), minRatio: minRatio);

  /// WCAG 2.x 对比度，取值 1.0（无对比）~ 21.0（黑白）。
  static double contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final lighter = luminanceA > luminanceB ? luminanceA : luminanceB;
    final darker = luminanceA > luminanceB ? luminanceB : luminanceA;
    return (lighter + 0.05) / (darker + 0.05);
  }
}
