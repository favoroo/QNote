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
  /// 用于「强调色当文字/图标贴在浅底上」的场景：背景偏亮就朝黑压、偏暗就朝白提，
  /// 小步进逼近直到达标，尽量保留原色相。已达标时原样返回。
  static Color readable(Color color, Color background, {double minRatio = minimumTextRatio}) {
    if (contrastRatio(color, background) >= minRatio) {
      return color;
    }
    // 朝与背景反差更大的方向调整，保证有限的调整量都能用在缩短对比度差距上。
    final target = background.computeLuminance() > 0.5 ? darkInk : lightInk;
    const step = 0.04;
    for (var t = step; t <= 1.0; t += step) {
      final candidate = Color.lerp(color, target, t)!;
      if (contrastRatio(candidate, background) >= minRatio) {
        return candidate;
      }
    }
    return target;
  }

  /// WCAG 2.x 对比度，取值 1.0（无对比）~ 21.0（黑白）。
  static double contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final lighter = luminanceA > luminanceB ? luminanceA : luminanceB;
    final darker = luminanceA > luminanceB ? luminanceB : luminanceA;
    return (lighter + 0.05) / (darker + 0.05);
  }
}
