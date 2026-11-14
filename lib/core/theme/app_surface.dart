import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';

/// 背景预设。
///
/// 索引用于 SharedPreferences 持久化，只能追加，不能调整既有顺序。
enum AppBackgroundPreset { system, light, dark, oled, accent, custom, paper, mist, pine }

/// 背景预设的展示顺序（与枚举索引解耦）。
///
/// 枚举索引是持久化键、只能追加，新增的纯色背景会排在 `custom` 之后；
/// 但设置页希望第 9 格仍是可打开拾色器的「自定义」，所以这里单独给出
/// 视觉顺序，并按明暗分组排列（浅色一行 / 深色一行 / 特殊一行）。
const List<AppBackgroundPreset> backgroundPresetDisplayOrder = [
  AppBackgroundPreset.light,
  AppBackgroundPreset.paper,
  AppBackgroundPreset.mist,
  AppBackgroundPreset.dark,
  AppBackgroundPreset.oled,
  AppBackgroundPreset.pine,
  AppBackgroundPreset.system,
  AppBackgroundPreset.accent,
  AppBackgroundPreset.custom,
];

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
  /// 画布始终等于用户所选颜色本身：主题色背景就是强调色原色、自定义背景就是所选色，
  /// 不做任何压暗/提亮。背景与按钮过近时，微调的是按钮那侧的强调色（见 [AppTheme]），
  /// 这样用户看到的底色和他选的颜色完全一致。
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
      case AppBackgroundPreset.paper:
        return const Color(0xFFF3E8D8);
      case AppBackgroundPreset.mist:
        return const Color(0xFFD6E4F0);
      case AppBackgroundPreset.pine:
        return const Color(0xFF0E2A22);
      case AppBackgroundPreset.accent:
        return accentColor;
      case AppBackgroundPreset.custom:
        return customColor;
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
      case AppBackgroundPreset.paper:
      case AppBackgroundPreset.mist:
      case AppBackgroundPreset.pine:
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
      case AppBackgroundPreset.paper:
      case AppBackgroundPreset.mist:
      case AppBackgroundPreset.pine:
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

/// 把 [color] 沿同色系微调，直到它与 [against] 至少保持 [minRatio] 的对比度。
///
/// 用于「背景切成了主题色/自定义色，而按钮、开关、选中态恰好也是这个颜色」的场景：
/// 在 HSL 空间保持色相并轻微收回一点饱和度（与 [_liftSurface] 同路），优先朝亮端
/// 抬升明度，避免往纯黑混色时把高饱和黄/绿/橙压成发灰发脏的泥巴色；只有画布
/// 本身接近纯白、亮端空间不够时才朝暗端收敛。
///
/// 注意调的是**第一个参数**（要移动的那个色），调用方传入的是强调色、参照物是画布；
/// 画布本身始终等于用户所选颜色，不会因为「避免按钮融进背景」而整页变暗。
Color ensureAccentGap(Color color, Color against, {double minRatio = 1.18}) {
  if (AppContrast.contrastRatio(color, against) >= minRatio) {
    return color;
  }
  final h = HSLColor.fromColor(color);
  final saturation = (h.saturation * 0.96).clamp(0.0, 1.0);
  const step = 0.005;

  // 优先朝亮端抬升：亮色系保持通透鲜亮，不会混黑变脏
  for (var i = 1; i <= 200; i++) {
    final lightness = (h.lightness + i * step).clamp(0.0, 1.0);
    final candidate = h.withLightness(lightness).withSaturation(saturation).toColor();
    if (AppContrast.contrastRatio(candidate, against) >= minRatio) {
      return candidate;
    }
    if (lightness >= 1.0) {
      break;
    }
  }

  // 画布接近纯白时亮端余量不足，改为沿同色系朝暗端压低
  for (var i = 1; i <= 200; i++) {
    final lightness = (h.lightness - i * step).clamp(0.0, 1.0);
    final candidate = h.withLightness(lightness).withSaturation(saturation).toColor();
    if (AppContrast.contrastRatio(candidate, against) >= minRatio) {
      return candidate;
    }
    if (lightness <= 0.0) {
      break;
    }
  }

  // 极端边界兜底
  return AppContrast.onColor(against);
}

/// 主题里按钮/FAB/开关实际使用的强调色。
///
/// 画布始终等于用户所选颜色；只有派生背景（主题色/自定义/OLED）下画布与强调色
/// 过近时，才把**按钮这一侧**推开一档，保证控件可见。legacy 主题保持原色。
///
/// 预览组件与主题必须走同一个函数，否则设置页看到的小圆点和真实按钮会对不上。
Color resolvePrimaryAccent(Color accentColor, AppSurfacePalette palette) =>
    palette.isLegacy ? accentColor : ensureAccentGap(accentColor, palette.canvas);

/// 卡片表面与画布的目标对比度。
///
/// 对齐纯黑画布（`#000000` 叠 7% 白 → `#121212`）的实测值：卡片只比画布亮「一丝」，
/// 既能靠明度差分层，又不会让用户觉得顶栏/卡片是另一种颜色。纯白画布因为已经到顶
/// 无法再提亮，才会退化成同色（只靠描边区分）。
const double _surfaceContrast = 1.12;

/// 把画布色朝白「提亮成卡片表面色」，同时保住原色相。
///
/// 早先的实现直接叠 55% 白，饱和的中亮度底色会被冲成灰米色（实测黄绿 `#B3CB41`
/// 变成 `#DDE8AA`，看起来像换了个颜色）。这里改在 HSL 空间只抬明度：
/// 按目标对比度二分反解明度，无论画布深浅，卡片与画布的明度差都保持一致，
/// 色相完全不变，饱和度轻微回收一点避免高亮后发荧光。
Color _liftSurface(Color canvas) {
  final h = HSLColor.fromColor(canvas);
  final saturation = (h.saturation * 0.96).clamp(0.0, 1.0);
  // 明度与亮度单调相关，二分找到刚好达到目标对比度的明度
  var low = h.lightness;
  var high = 1.0;
  for (var i = 0; i < 16; i++) {
    final mid = (low + high) / 2;
    final candidate = h.withLightness(mid).withSaturation(saturation).toColor();
    if (AppContrast.contrastRatio(canvas, candidate) >= _surfaceContrast) {
      high = mid;
    } else {
      low = mid;
    }
  }
  // 画布已经接近纯白时提不上去，落到白色（与纯白预设一致）
  return h.withLightness(high).withSaturation(saturation).toColor();
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

    // 表面：浅底朝白提亮一丝（对齐纯黑画布的 1.12 对比度），深底同样只轻微抬升；
    // 抬升若把正文对比度压到 AA 以下，深色底改用轻微压暗，靠表面色差区分卡片
    Color surface;
    if (isDark) {
      final lifted = Color.alphaBlend(Colors.white.withValues(alpha: 0.07), canvas);
      surface = AppContrast.contrastRatio(ink, lifted) >= AppContrast.minimumTextRatio
          ? lifted
          : Color.alphaBlend(Colors.black.withValues(alpha: 0.06), canvas);
    } else {
      surface = canvasLuminance >= 0.85 ? Colors.white : _liftSurface(canvas);
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
