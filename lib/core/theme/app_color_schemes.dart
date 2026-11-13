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
/// 交错排列，除保留一套纯黑 + 正红外，都用有彩度画布配撞色强调色。
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
  // 纯黑 + 高饱和正红：暗色下红色最通透，也是用户实测认可的搭配
  AppColorSchemePreset(
    name: '赤焰黑',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.oled),
    accentColor: Color(0xFFF80004),
  ),
  // 森林绿 + 珊瑚：冷绿底上放一块暖珊瑚，安静里带一点跳
  AppColorSchemePreset(
    name: '松林珊瑚',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF123B2E)),
    accentColor: Color(0xFFFF7A6B),
  ),
  // 深紫 + 薄荷：紫绿互补，偏霓虹/赛博感
  AppColorSchemePreset(
    name: '紫夜薄荷',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFF2B1B4A)),
    accentColor: Color(0xFF3DDC97),
  ),
  // 雾霾蓝 + 深琥珀：冷蓝底压深暖色，清爽但不过分甜
  AppColorSchemePreset(
    name: '雾蓝琥珀',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFFBCD7EE)),
    accentColor: Color(0xFFB45309),
  ),
  // 香芋紫 + 葡萄紫：同色系深浅搭配，柔和但有层次
  AppColorSchemePreset(
    name: '香芋紫',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFFDCCBF2)),
    accentColor: Color(0xFF7B2CBF),
  ),
  // 奶茶 + 砖红：暖奶茶底配砖红，偏秋冬织物感
  AppColorSchemePreset(
    name: '奶茶砖红',
    background: AppBackgroundSetting(preset: AppBackgroundPreset.custom, customColor: Color(0xFFE0C6AE)),
    accentColor: Color(0xFFB23A2E),
  ),
];
