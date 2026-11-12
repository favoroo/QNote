import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';

/// 背景预设。
///
/// 索引用于 SharedPreferences 持久化，只能追加，不能调整既有顺序。
enum AppBackgroundPreset { system, light, dark, oled, accent, custom }

/// 背景设置：预设 + 自定义颜色。
@immutable
class AppBackgroundSetting {
  /// 自定义背景的初始色，选暖纸色避免第一次进入时是刺眼的纯色。
  static const Color defaultCustomColor = Color(0xFFF2E9DC);

  const AppBackgroundSetting({this.preset = AppBackgroundPreset.system, this.customColor = defaultCustomColor});

  final AppBackgroundPreset preset;
  final Color customColor;

  AppBackgroundSetting copyWith({AppBackgroundPreset? preset, Color? customColor}) =>
      AppBackgroundSetting(preset: preset ?? this.preset, customColor: customColor ?? this.customColor);

  /// 当前槽位实际生效的画布色。
  ///
  /// 主题色/自定义色与强调色过近时会自动偏移，避免背景和按钮/图标融在一起。
  Color resolveCanvas({required Color accentColor, required Brightness platformBrightness}) {
    switch (preset) {
      case AppBackgroundPreset.system:
        return platformBrightness == Brightness.dark
            ? AppSurfacePalette.legacyDark.canvas
            : AppSurfacePalette.legacyLight.canvas;
      case AppBackgroundPreset.light:
        return AppSurfacePalette.legacyLight.canvas;
      case AppBackgroundPreset.dark:
        return AppSurfacePalette.legacyDark.canvas;
      case AppBackgroundPreset.oled:
        return const Color(0xFF000000);
      case AppBackgroundPreset.accent:
        return ensureAccentGap(accentColor, accentColor);
      case AppBackgroundPreset.custom:
        return ensureAccentGap(customColor, accentColor);
    }
  }

  /// 当前槽位应使用的表面调色板。
  ///
  /// 浅色/深色/跟随系统沿用既有的精确色表，保证默认观感不变；其余预设按画布推导。
  AppSurfacePalette resolvePalette({required Color accentColor, required Brightness platformBrightness}) {
    switch (preset) {
      case AppBackgroundPreset.system:
        return platformBrightness == Brightness.dark ? AppSurfacePalette.legacyDark : AppSurfacePalette.legacyLight;
      case AppBackgroundPreset.light:
        return AppSurfacePalette.legacyLight;
      case AppBackgroundPreset.dark:
        return AppSurfacePalette.legacyDark;
      case AppBackgroundPreset.oled:
      case AppBackgroundPreset.accent:
      case AppBackgroundPreset.custom:
        final canvas = resolveCanvas(accentColor: accentColor, platformBrightness: platformBrightness);
        return AppSurfacePalette.derived(canvas);
    }
  }

  /// 旧版 theme_mode 兼容索引（system=0 / light=1 / dark=2）。
  ///
  /// 绝对背景没有独立的深浅模式，这里按实际画布推导，仅供旧读取方与迁移使用。
  int legacyThemeModeIndex({required Color accentColor}) {
    switch (preset) {
      case AppBackgroundPreset.system:
        return 0;
      case AppBackgroundPreset.light:
        return 1;
      case AppBackgroundPreset.dark:
      case AppBackgroundPreset.oled:
        return 2;
      case AppBackgroundPreset.accent:
      case AppBackgroundPreset.custom:
        final canvas = resolveCanvas(accentColor: accentColor, platformBrightness: Brightness.light);
        return AppContrast.onColor(canvas) == AppContrast.lightInk ? 2 : 1;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AppBackgroundSetting && other.preset == preset && other.customColor.toARGB32() == customColor.toARGB32();

  @override
  int get hashCode => Object.hash(preset, customColor.toARGB32());
}

/// 保证背景与强调色至少保持 [minRatio] 的 WCAG 对比度。
///
/// 用于「主题色背景」「自定义色恰好等于主题色」等场景：朝黑/朝白两个方向逐级尝试，
/// 取调整量更小的一侧，尽量保留原色相与明度，只做「一点点偏差」。
Color ensureAccentGap(Color background, Color accent, {double minRatio = 1.3}) {
  if (AppContrast.contrastRatio(background, accent) >= minRatio) {
    return background;
  }
  const step = 0.02;
  for (var t = step; t <= 1.0; t += step) {
    Color? candidate;
    for (final target in const [Colors.black, Colors.white]) {
      final adjusted = Color.lerp(background, target, t)!;
      if (AppContrast.contrastRatio(adjusted, accent) >= minRatio) {
        candidate = adjusted;
        break;
      }
    }
    if (candidate != null) {
      return candidate;
    }
  }
  // 黑白中总有一侧能把对比度拉到 1.3 以上，这里只是兜底
  return AppContrast.onColor(accent);
}

/// 表面调色板：把背景色推导成 App 需要的全部中性表面与文字角色。
///
/// 不依赖 [BuildContext]，可纯函数测试。浅色/深色沿用既有精确色表，
/// OLED/主题色/自定义背景则按画布亮度与对比度实时推导。
@immutable
class AppSurfacePalette {
  const AppSurfacePalette({
    required this.canvas,
    required this.surface,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.brightness,
    required this.isLegacy,
  });

  /// 既有浅色主题的精确色表，保持默认观感不变。
  static const AppSurfacePalette legacyLight = AppSurfacePalette(
    canvas: Color(0xFFF9F9FF),
    surface: Colors.white,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFF9F9FF),
    surfaceContainer: Color(0xFFF2F3FD),
    surfaceContainerHigh: Color(0xFFECEDEF),
    surfaceContainerHighest: Color(0xFFE4E5EC),
    onSurface: Color(0xFF191B23),
    onSurfaceVariant: Color(0xFF727785),
    outline: Color(0xFFC2C6D6),
    outlineVariant: Color(0xFFE4E5EC),
    inverseSurface: Color(0xFF30303C),
    onInverseSurface: Color(0xFFF2F3FD),
    brightness: Brightness.light,
    isLegacy: true,
  );

  /// 既有深色主题的精确色表，保持默认观感不变。
  static const AppSurfacePalette legacyDark = AppSurfacePalette(
    canvas: Color(0xFF111318),
    surface: Color(0xFF1A1D24),
    surfaceContainerLowest: Color(0xFF111318),
    surfaceContainerLow: Color(0xFF1A1D24),
    surfaceContainer: Color(0xFF22252C),
    surfaceContainerHigh: Color(0xFF2A2D36),
    surfaceContainerHighest: Color(0xFF363A45),
    onSurface: Color(0xFFE2E2E9),
    onSurfaceVariant: Color(0xFF8E94A3),
    outline: Color(0xFF383C47),
    outlineVariant: Color(0xFF2A2D36),
    inverseSurface: Color(0xFFE2E2E9),
    onInverseSurface: Color(0xFF30303C),
    brightness: Brightness.dark,
    isLegacy: true,
  );

  /// 按任意画布推导中性表面与文字色。
  factory AppSurfacePalette.derived(Color canvas) {
    // 黑白中总有一侧对画布的对比度 ≥ 4.58，先用它确定整页的明暗基调
    final ink = AppContrast.onColor(canvas);
    final isDark = ink == AppContrast.lightInk;
    final canvasLuminance = canvas.computeLuminance();

    // 表面：浅底大量朝白抬升（接近白底时直接白），深底只轻微抬升；
    // 抬升若把正文对比度压到 AA 以下，深色底改用轻微压暗，靠表面色差区分卡片
    Color surface;
    if (isDark) {
      final lifted = Color.alphaBlend(Colors.white.withValues(alpha: 0.07), canvas);
      surface = AppContrast.contrastRatio(ink, lifted) >= AppContrast.minimumTextRatio
          ? lifted
          : Color.alphaBlend(Colors.black.withValues(alpha: 0.06), canvas);
    } else {
      surface = canvasLuminance >= 0.85 ? Colors.white : Color.alphaBlend(Colors.white.withValues(alpha: 0.55), canvas);
    }

    // 容器沿墨色方向微移，形成层级；最大偏移必须保证墨色在最高容器上仍可读，
    // 中间亮度背景会自动收窄层级幅度，避免容器越深文字越糊
    final safeOverlay = _maxOverlayAlpha(ink: ink, background: canvas, minRatio: 4.6);
    final aestheticMax = isDark ? 0.14 : 0.10;
    final overlayMax = safeOverlay.clamp(0.0, aestheticMax).toDouble();
    Color containerAt(double factor) => Color.alphaBlend(ink.withValues(alpha: overlayMax * factor), canvas);

    final surfaceContainer = containerAt(1 / 3);
    final surfaceContainerHigh = containerAt(2 / 3);
    final surfaceContainerHighest = containerAt(1);

    // 正文/次级文字对「最不利表面」校准：离墨色最近的最高容器最容易掉对比度，
    // 它能达标，画布/普通卡片就都能达标
    final onSurface = AppContrast.readable(Color.lerp(ink, canvas, 0.08)!, surfaceContainerHighest);
    final onSurfaceVariant = AppContrast.readable(Color.lerp(ink, canvas, 0.42)!, surfaceContainerHighest);

    final outline = Color.alphaBlend(ink.withValues(alpha: isDark ? 0.20 : 0.26), canvas);
    final outlineVariant = Color.alphaBlend(ink.withValues(alpha: isDark ? 0.10 : 0.12), canvas);
    final inverseSurface = Color.alphaBlend(ink.withValues(alpha: 0.90), canvas);
    final onInverseSurface = AppContrast.readable(isDark ? Colors.black : Colors.white, inverseSurface);

    return AppSurfacePalette(
      canvas: canvas,
      surface: surface,
      surfaceContainerLowest: isDark ? canvas : surface,
      surfaceContainerLow: isDark ? surface : canvas,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest: surfaceContainerHighest,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceVariant,
      outline: outline,
      outlineVariant: outlineVariant,
      inverseSurface: inverseSurface,
      onInverseSurface: onInverseSurface,
      brightness: isDark ? Brightness.dark : Brightness.light,
      isLegacy: false,
    );
  }

  final Color canvas;
  final Color surface;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Brightness brightness;

  /// 是否沿用浅色/深色的既有色表。
  ///
  /// 派生背景会把 primary 调成可读版本；legacy 主题保持原始强调色，避免默认观感变化。
  final bool isLegacy;

  bool get isDark => brightness == Brightness.dark;

  /// 二分查找「墨色叠加到画布上」的最大安全透明度。
  static double _maxOverlayAlpha({required Color ink, required Color background, required double minRatio}) {
    var low = 0.0;
    var high = 0.30;
    for (var i = 0; i < 12; i++) {
      final mid = (low + high) / 2;
      final candidate = Color.alphaBlend(ink.withValues(alpha: mid), background);
      if (AppContrast.contrastRatio(ink, candidate) >= minRatio) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return low;
  }
}
