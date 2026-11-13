import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';

/// 外观偏好的持久化键。
///
/// 集中在这里是为了让「首帧前预读」（[AppearanceBootstrap]）、主题 Provider 的
/// 读写、以及 Android 原生启动窗口的读取三方使用同一套键名，避免拼写漂移。
abstract final class AppearanceKeys {
  static const String backgroundPreset = 'background_preset';
  static const String backgroundCustomColor = 'background_custom_color';
  static const String accentColor = 'accent_color';
  static const String legacyThemeMode = 'theme_mode';

  /// 原生启动窗口使用的画布色（浅色 / 深色两个槽位）。
  ///
  /// Android 在 `MainActivity.onCreate` 里读取，用于在 Flutter 首帧前把窗口底色
  /// 铺成 App 的真实画布色——否则系统深色启动屏会先显示一屏深色，
  /// 再跳到用户的浅色主题，形成一次可见的「深 → 浅」闪变。
  static const String launchCanvasLight = 'launch_canvas_light';
  static const String launchCanvasDark = 'launch_canvas_dark';

  /// 原生启动屏应强制使用的明暗（-1 跟随系统 / 0 浅色 / 1 深色）。
  ///
  /// Android 12+ 的系统启动屏在 `onCreate` 之前就由系统绘制，改窗口底色已经来不及；
  /// 只能在 `attachBaseContext` 里覆盖 uiMode，让启动屏主题解析到用户实际选择的
  /// 那一套 `values` / `values-night`。这里把「用户期望的明暗」算好交给原生，
  /// 跟随系统时存 -1，不做覆盖。
  static const String launchNightMode = 'launch_night_mode';

  /// 第 9 个「我的搭配」槽位保存的背景预设、自定义背景色与主题色。
  ///
  /// 三个键必须同时存在才算一份有效搭配；缺任意一个都按「尚未保存」处理，
  /// 避免历史数据只写了一半时恢复出诡异的半套配色。
  static const String savedSchemeBackgroundPreset = 'saved_scheme_background_preset';
  static const String savedSchemeBackgroundCustomColor = 'saved_scheme_background_custom_color';
  static const String savedSchemeAccentColor = 'saved_scheme_accent_color';
}

/// 从持久化值解析背景设置。
///
/// [presetIndex] 缺失时按旧版 `theme_mode` 迁移（0 跟随系统 / 1 浅色 / 2 深色）。
/// 抽成纯函数是为了让预读与 Provider 的异步加载共用同一套解析规则，
/// 也方便直接写单测覆盖各种历史数据组合。
AppBackgroundSetting resolveBackgroundSetting({
  required int? presetIndex,
  required int? customColorValue,
  required int? legacyThemeMode,
}) {
  final customColor = customColorValue == null ? AppBackgroundSetting.defaultCustomColor : Color(customColorValue);
  if (presetIndex == null) {
    final migrated = switch (legacyThemeMode ?? 0) {
      1 => AppBackgroundPreset.light,
      2 => AppBackgroundPreset.dark,
      _ => AppBackgroundPreset.system,
    };
    return AppBackgroundSetting(preset: migrated, customColor: customColor);
  }
  // 索引越界（历史数据或降级安装）时夹到合法区间，不让首帧崩在取值上
  final preset = AppBackgroundPreset.values[presetIndex.clamp(0, AppBackgroundPreset.values.length - 1)];
  return AppBackgroundSetting(preset: preset, customColor: customColor);
}

/// 首帧前的外观快照。
///
/// 主题 Provider 原本是「先用默认值渲染、异步读到偏好再切换」，于是首帧总是
/// 跟随系统明暗：手机是深色模式 + App 设了浅色背景时，用户会先看到一屏深色，
/// 再被主题动画推到浅色。这里在 `runApp` 之前把偏好读进内存，Provider 直接以
/// 快照作为初始 state，首帧就是终态，从根本上消除这次闪变。
///
/// 只有 [warmUp] 会填充快照；未调用时（例如 widget 测试）Provider 仍走原来的
/// 异步加载路径，行为与测试隔离性都不变。
abstract final class AppearanceBootstrap {
  static AppBackgroundSetting? _background;
  static Color? _accentColor;

  /// 首帧前读到的背景设置；未预热时为 null。
  static AppBackgroundSetting? get background => _background;

  /// 首帧前读到的强调色；未预热时为 null。
  static Color? get accentColor => _accentColor;

  /// 预热外观快照。必须在 `runApp` 之前 await。
  ///
  /// `SharedPreferences` 实例在进程内是单例，这里与 Logger 的初始化共用同一份，
  /// 额外开销只有几次同步读 map。
  static Future<void> warmUp() async {
    final prefs = await SharedPreferences.getInstance();
    _background = resolveBackgroundSetting(
      presetIndex: prefs.getInt(AppearanceKeys.backgroundPreset),
      customColorValue: prefs.getInt(AppearanceKeys.backgroundCustomColor),
      legacyThemeMode: prefs.getInt(AppearanceKeys.legacyThemeMode),
    );
    final accent = prefs.getInt(AppearanceKeys.accentColor);
    _accentColor = accent == null ? AppTheme.primaryDefault : Color(accent);
    // 历史安装可能还没写过启动色，首次启动时补一份，下次冷启动就能用上
    await persistLaunchCanvas(prefs, background: _background!, accentColor: _accentColor!);
  }

  /// 把当前外观对应的画布色写进偏好，供原生启动窗口在 Flutter 首帧前铺底。
  ///
  /// 两个槽位都要写：系统浅色/深色启动屏分别读各自的键。这样无论手机处于哪种
  /// 系统主题，原生窗口的底色都与 App 首帧完全一致，不会出现「启动屏一种颜色、
  /// Flutter 首帧另一种颜色」的跳变。
  ///
  /// 写成 `#RRGGBB` 字符串而不是 int：Android 侧读的是无符号十六进制，
  /// 直接存 ARGB int 在 Kotlin 里会变成负的 Long，解析容易出错。
  static Future<void> persistLaunchCanvas(
    SharedPreferences prefs, {
    required AppBackgroundSetting background,
    required Color accentColor,
  }) async {
    for (final brightness in Brightness.values) {
      final canvas = background.resolveCanvas(accentColor: accentColor, platformBrightness: brightness);
      final hex = '#${canvas.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
      final key = brightness == Brightness.dark ? AppearanceKeys.launchCanvasDark : AppearanceKeys.launchCanvasLight;
      if (prefs.getString(key) != hex) {
        await prefs.setString(key, hex);
      }
    }

    // 固定浅色/深色/OLED/主题色/自定义背景都能推出确定明暗，让原生启动屏直接用它，
    // 不再跟着系统走；只有「跟随系统」才交还给系统决定。
    final nightMode = switch (background.preset) {
      AppBackgroundPreset.system => -1,
      _ => background.resolvePalette(accentColor: accentColor, platformBrightness: Brightness.light).isDark ? 1 : 0,
    };
    if (prefs.getInt(AppearanceKeys.launchNightMode) != nightMode) {
      await prefs.setInt(AppearanceKeys.launchNightMode, nightMode);
    }
  }

  /// 清空快照（仅测试使用）。
  static void resetForTest() {
    _background = null;
    _accentColor = null;
  }
}
