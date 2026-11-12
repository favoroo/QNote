import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';

/// 背景设置：预设 + 自定义颜色。
///
/// 旧的 `theme_mode` 只保留为兼容字段：深浅不再独立控制，实际明暗由背景色推导。
final backgroundSettingProvider = NotifierProvider<BackgroundSettingNotifier, AppBackgroundSetting>(
  BackgroundSettingNotifier.new,
);

class BackgroundSettingNotifier extends Notifier<AppBackgroundSetting> {
  @override
  AppBackgroundSetting build() {
    // 构造时异步加载持久化的偏好，加载完成前先用默认值，避免阻塞首帧
    _load();
    _listenWorkspaceEvents();
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
    final storedIndex = prefs.getInt('background_preset');
    final customValue = prefs.getInt('background_custom_color');
    final customColor = customValue == null ? AppBackgroundSetting.defaultCustomColor : Color(customValue);

    final AppBackgroundPreset preset;
    if (storedIndex != null) {
      preset = AppBackgroundPreset.values[storedIndex.clamp(0, AppBackgroundPreset.values.length - 1)];
    } else {
      // 旧版本只存 theme_mode，这里迁移成对应背景预设
      preset = switch (prefs.getInt('theme_mode') ?? 0) {
        1 => AppBackgroundPreset.light,
        2 => AppBackgroundPreset.dark,
        _ => AppBackgroundPreset.system,
      };
    }
    state = AppBackgroundSetting(preset: preset, customColor: customColor);
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

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('background_preset', state.preset.index);
    await prefs.setInt('background_custom_color', state.customColor.toARGB32());
    // 同步旧 theme_mode，旧的 VFS 读取方与历史数据仍能理解当前明暗
    final accentColor = ref.read(accentColorProvider);
    await prefs.setInt('theme_mode', state.legacyThemeModeIndex(accentColor: accentColor));
  }
}

final accentColorProvider = NotifierProvider<AccentColorNotifier, Color>(AccentColorNotifier.new);

class AccentColorNotifier extends Notifier<Color> {
  @override
  Color build() {
    _load();
    _listenWorkspaceEvents();
    return const Color(0xFF005BCB);
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
    final value = prefs.getInt('accent_color');
    if (value != null) {
      state = Color(value);
    }
  }

  Future<void> setAccentColor(Color color) async {
    state = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accent_color', color.toARGB32());
  }
}

final presetAccentColors = [
  const Color(0xFF005BCB), // 经典蓝 (Classic Blue)
  const Color(0xFFC5E803), // 荧光黄绿
  const Color(0xFFE91E8C), // 玫瑰粉红
  const Color(0xFF00E676), // 春天亮绿
  const Color(0xFFFF3B30), // 活力红 (iOS 系统红)
  const Color(0xFFFF9500), // 活力橙 (iOS 系统橙)
  const Color(0xFF00BCD4), // 湖水青 (Material Cyan 500)
  const Color(0xFF7C4DFF), // 典雅紫 (Deep Purple A200)
];
