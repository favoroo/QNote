import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';

/// 一套推荐的「背景 + 主题色」搭配。
///
/// 组合经过挑选：画布与强调色保持足够对比，深色方案用高饱和亮色提神，
/// 浅色方案用低明度强调色保证按钮文字可读。
@immutable
class AppColorSchemePreset {
  const AppColorSchemePreset({required this.name, required this.background, required this.accentColor});

  /// 展示名称，控制在 3 个字以内，避免小屏下换行。
  final String name;

  /// 背景设置（含预设与自定义色）。
  final AppBackgroundSetting background;

  /// 主题色。
  final Color accentColor;

  /// 当前外观是否就是这套搭配。
  ///
  /// 非自定义预设不使用 [AppBackgroundSetting.customColor]，比较时忽略它：
  /// 用户改过自定义背景色后，同一套搭配仍应显示为选中。
  bool matches({required AppBackgroundSetting background, required Color accentColor}) {
    if (background.preset != this.background.preset || accentColor.toARGB32() != this.accentColor.toARGB32()) {
      return false;
    }
    return this.background.preset != AppBackgroundPreset.custom ||
        background.customColor.toARGB32() == this.background.customColor.toARGB32();
  }

  /// 生成应用后的背景设置。
  ///
  /// 预设方案（浅色/深色/OLED 等）不读取自定义色，保留用户已有的自定义背景色，
  /// 避免一键搭配把用户调过的颜色顺手重置。
  AppBackgroundSetting resolveBackground(AppBackgroundSetting current) {
    if (background.preset == AppBackgroundPreset.custom) {
      return background;
    }
    return AppBackgroundSetting(preset: background.preset, customColor: current.customColor);
  }
}

/// 第 9 个槽位「我的搭配」的展示名称。
const String savedColorSchemeName = '我的搭配';

/// 内置推荐搭配。
///
/// 首套是 App 默认的经典蓝 + 浅色底，一键回到初始观感；其余深色底与浅色底
/// 交错排列，画布与强调色多取自流行作品与经典品牌配色。
const List<AppColorSchemePreset> recommendedColorSchemes = [
  // 经典蓝 + 浅色底：App 默认主题色落在近白画布上，干净通透，作为首选保底
  AppColorSchemePreset(
    name: '经典蓝',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.light),
    accentColor: Color(0xFF005BCB),
  ),
  // 克莱因蓝 + 亮橙：互补色撞色，蓝底沉稳、橙色按钮跳脱
  AppColorSchemePreset(
    name: '蓝橙电波',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF002FA7)),
    accentColor: Color(0xFFFF6B18),
  ),
  // 暖黑 + 赛博黄：赛博朋克 2077「夜之城」同款黑黄撞色，列表里唯一的黄色系
  AppColorSchemePreset(
    name: '夜之城',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF15120B)),
    accentColor: Color(0xFFFCEE21),
  ),
  // OLED 纯黑 + 代码绿：黑客帝国终端雨，纯黑画布最显荧光绿
  AppColorSchemePreset(
    name: '黑客帝国',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.oled),
    accentColor: Color(0xFF00FF41),
  ),
  // 初号机紫 + 荧光黄绿：EVA 初号机同款撞色，深紫画布提饱和、强调色走荧光绿
  AppColorSchemePreset(
    name: '初号机',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF301B6A)),
    accentColor: Color(0xFFA6FF4D),
  ),
  // 薄荷白 + 蒂芙尼蓝：经典品牌青蓝，浅色系的清爽担当
  AppColorSchemePreset(
    name: '蒂芙尼',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFFF3FAF9)),
    accentColor: Color(0xFF0ABAB5),
  ),
  // 淡粉 + 深玫红：蒸汽波粉紫霓虹的浅色版，甜而不腻
  AppColorSchemePreset(
    name: '蒸汽波',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFFFAE7F2)),
    accentColor: Color(0xFFA93A90),
  ),
  // 纯黑 + 高饱和正红：暗色下红色最通透，也是用户实测认可的搭配
  AppColorSchemePreset(
    name: '赤焰黑',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.oled),
    accentColor: Color(0xFFF80004),
  ),
];
