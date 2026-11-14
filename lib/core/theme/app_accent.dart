import 'package:flutter/material.dart';

/// 可读强调色前景令牌。
///
/// 同一支主题色在 App 里承担两种角色，对对比度的要求完全相反：
/// - **实心底**（FAB、实心按钮、开关、选项卡）：只需要和背景「分得开」，越鲜艳越好；
/// - **前景**（文字、图标、细描边）：必须读到 4.5:1，否则等于看不见。
///
/// 派生背景（OLED / 主题色背景 / 自定义背景）下画布本身就可能就是这支强调色
/// （同色系主题色背景最典型），此时 `ColorScheme.primary` 当字色只有 ~1.05:1。
/// 主题构建时把「同一支色相、校准过对比度」的前景色放进 [AppAccentInk]，
/// 组件层统一通过 [AppThemeAccent.accentInk] 取用。
///
/// legacy（浅色/深色预设）沿用既有观感，不注册该扩展，[AppThemeAccent.accentInk]
/// 自然回落到 `colorScheme.primary`，默认主题不发生任何变化。
@immutable
class AppAccentInk extends ThemeExtension<AppAccentInk> {
  const AppAccentInk({required this.ink, this.needsOutline = false});

  /// 可读的强调色前景：对画布、卡片与容器淡底均达到正文对比度。
  final Color ink;

  /// 强调色与画布/表面过近、实心色块自身轮廓会「糊」进背景时为 true。
  ///
  /// 这类主题下，用 primary 铺底的胶囊/指示块需要补一圈细描边交代边界
  /// （同色系主题色背景最典型：色块颜色正确，只是没有边界）。
  final bool needsOutline;

  @override
  AppAccentInk copyWith({Color? ink, bool? needsOutline}) =>
      AppAccentInk(ink: ink ?? this.ink, needsOutline: needsOutline ?? this.needsOutline);

  @override
  AppAccentInk lerp(ThemeExtension<AppAccentInk>? other, double t) => other is AppAccentInk
      ? AppAccentInk(ink: Color.lerp(ink, other.ink, t)!, needsOutline: t < 0.5 ? needsOutline : other.needsOutline)
      : this;
}

/// 从 [ThemeData] 取可读强调色前景的便捷入口。
extension AppThemeAccent on ThemeData {
  /// 把主题色当**文字/图标/细线**画在画布或卡片上时的实际用色。
  ///
  /// 与 `colorScheme.primary` 的区别只在派生背景且强调色贴住表面时才出现；
  /// 实心底请继续用 `colorScheme.primary` / `colorScheme.onPrimary`。
  Color get accentInk => extension<AppAccentInk>()?.ink ?? colorScheme.primary;

  /// 实心主题色块的边界是否会糊进背景（派生背景且强调色贴近表面时为 true）。
  bool get accentNeedsOutline => extension<AppAccentInk>()?.needsOutline ?? false;
}
