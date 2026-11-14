import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/theme/app_color_schemes.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/theme/appearance_bootstrap.dart';

/// 背景设置：预设 + 自定义颜色。
///
/// 旧的 `theme_mode` 只保留为兼容字段：深浅不再独立控制，实际明暗由背景色推导。
final backgroundSettingProvider = NotifierProvider<BackgroundSettingNotifier, AppBackgroundSetting>(
  BackgroundSettingNotifier.new,
);

class BackgroundSettingNotifier extends Notifier<AppBackgroundSetting> {
  @override
  AppBackgroundSetting build() {
    _listenWorkspaceEvents();
    // 冷启动时 [AppearanceBootstrap.warmUp] 已在 runApp 前读到偏好，直接以它为初始
    // state：否则首帧只能用「跟随系统」的默认值，手机深色 + App 浅色设置会先闪一屏
    // 深色再切浅色。没有预热（如 widget 测试）时仍走异步加载兜底。
    final bootstrapped = AppearanceBootstrap.background;
    if (bootstrapped != null) {
      return bootstrapped;
    }
    _load();
    return const AppBackgroundSetting();
  }

  void _listenWorkspaceEvents() {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path == '/settings/appearance.json') {
        _load();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // 解析规则与首帧预热共用 [resolveBackgroundSetting]，避免两处迁移逻辑漂移
    state = resolveBackgroundSetting(
      presetIndex: prefs.getInt(AppearanceKeys.backgroundPreset),
      customColorValue: prefs.getInt(AppearanceKeys.backgroundCustomColor),
      legacyThemeMode: prefs.getInt(AppearanceKeys.legacyThemeMode),
    );
  }

  Future<void> setPreset(AppBackgroundPreset preset) async {
    state = state.copyWith(preset: preset);
    await _persist();
  }

  Future<void> setCustomColor(Color color) async {
    state = state.copyWith(preset: AppBackgroundPreset.custom, customColor: color);
    await _persist();
  }

  Future<void> reset() async {
    state = const AppBackgroundSetting();
    await _persist();
  }

  /// 一键应用推荐搭配：背景与主题色同时切换。
  ///
  /// 先切主题色再落背景，最后一次 [_persist] 会用新的强调色重算 legacy theme_mode
  /// 与原生启动画布，避免持久化字段短暂停在旧搭配上。
  Future<void> applyScheme(AppBackgroundSetting background, Color accentColor) async {
    await ref.read(accentColorProvider.notifier).setAccentColor(accentColor);
    state = background;
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppearanceKeys.backgroundPreset, state.preset.index);
    await prefs.setInt(AppearanceKeys.backgroundCustomColor, state.customColor.toARGB32());
    // 同步旧 theme_mode，旧的 VFS 读取方与历史数据仍能理解当前明暗
    final accentColor = ref.read(accentColorProvider);
    await prefs.setInt(AppearanceKeys.legacyThemeMode, state.legacyThemeModeIndex(accentColor: accentColor));
    // 同步原生启动窗口底色：下次冷启动时窗口首帧就与 App 一致
    await AppearanceBootstrap.persistLaunchCanvas(prefs, background: state, accentColor: accentColor);
  }
}

final accentColorProvider = NotifierProvider<AccentColorNotifier, Color>(AccentColorNotifier.new);

class AccentColorNotifier extends Notifier<Color> {
  @override
  Color build() {
    _listenWorkspaceEvents();
    // 与背景同理：首帧就用预热到的强调色，否则默认蓝色会先闪一下再切到用户色
    final bootstrapped = AppearanceBootstrap.accentColor;
    if (bootstrapped != null) {
      return bootstrapped;
    }
    _load();
    return AppTheme.primaryDefault;
  }

  void _listenWorkspaceEvents() {
    void onWorkspaceChange(WorkspaceChangeEvent event) {
      if (event.path == '/settings/appearance.json') {
        _load();
      }
    }

    WorkspaceEventBus.instance.addListener(onWorkspaceChange);
    ref.onDispose(() {
      WorkspaceEventBus.instance.removeListener(onWorkspaceChange);
    });
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(AppearanceKeys.accentColor);
    if (value != null) {
      state = Color(value);
    }
  }

  Future<void> setAccentColor(Color color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppearanceKeys.accentColor, color.toARGB32());
    // 主题色背景 / 自定义背景的启动色随强调色微调，换色后要同步给原生启动窗口
    await AppearanceBootstrap.persistLaunchCanvas(
      prefs,
      background: ref.read(backgroundSettingProvider),
      accentColor: color,
    );
  }
}

final presetAccentColors = [
  const Color(0xFF005BCB), // 经典蓝 (Classic Blue)
  const Color(0xFFC5E803), // 荧光黄绿
  const Color(0xFFE91E8C), // 玫瑰粉红
  const Color(0xFF00E676), // 春天亮绿
  const Color(0xFFF80004), // 赤焰红（与「赤焰黑」推荐搭配同一红）
  const Color(0xFFFF9500), // 活力橙 (iOS 系统橙)
  const Color(0xFF00BCD4), // 湖水青 (Material Cyan 500)
  const Color(0xFF7C4DFF), // 典雅紫 (Deep Purple A200)
];

/// 用户在第 9 个槽位保存的「我的搭配」。
///
/// 与内置推荐组合同构，方便复用预览、选中匹配与一键套用逻辑；
/// 保存在本地 SharedPreferences 中，不参与外观的 WebDAV 同步。
final savedColorSchemeProvider = NotifierProvider<SavedColorSchemeNotifier, AppColorSchemePreset?>(
  SavedColorSchemeNotifier.new,
);

class SavedColorSchemeNotifier extends Notifier<AppColorSchemePreset?> {
  /// 用户在本实例内改过槽位后，异步加载不能再把旧值盖回来。
  bool _touched = false;

  @override
  AppColorSchemePreset? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_touched) {
      return;
    }
    final presetIndex = prefs.getInt(AppearanceKeys.savedSchemeBackgroundPreset);
    final customColorValue = prefs.getInt(AppearanceKeys.savedSchemeBackgroundCustomColor);
    final accentColorValue = prefs.getInt(AppearanceKeys.savedSchemeAccentColor);
    // 三个键缺一不可：历史数据只写了一半时按「未保存」处理，避免恢复出半套配色
    if (presetIndex == null || customColorValue == null || accentColorValue == null) {
      return;
    }
    // 索引越界（历史数据或降级安装）时夹到合法区间，不让页面崩在取值上
    final preset = AppBackgroundPreset.values[presetIndex.clamp(0, AppBackgroundPreset.values.length - 1)];
    state = AppColorSchemePreset(
      name: savedColorSchemeName,
      background: AppBackgroundSetting(preset: preset, customColor: Color(customColorValue)),
      accentColor: Color(accentColorValue),
    );
  }

  /// 把当前背景与主题色保存为「我的搭配」，已存在时直接覆盖。
  Future<void> save(AppBackgroundSetting background, Color accentColor) async {
    _touched = true;
    state = AppColorSchemePreset(name: savedColorSchemeName, background: background, accentColor: accentColor);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppearanceKeys.savedSchemeBackgroundPreset, background.preset.index);
    await prefs.setInt(AppearanceKeys.savedSchemeBackgroundCustomColor, background.customColor.toARGB32());
    await prefs.setInt(AppearanceKeys.savedSchemeAccentColor, accentColor.toARGB32());
  }

  /// 清空保存槽位，界面回到「保存当前」。
  Future<void> clear() async {
    _touched = true;
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppearanceKeys.savedSchemeBackgroundPreset);
    await prefs.remove(AppearanceKeys.savedSchemeBackgroundCustomColor);
    await prefs.remove(AppearanceKeys.savedSchemeAccentColor);
  }
}
