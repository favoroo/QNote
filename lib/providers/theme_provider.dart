import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// P2-30: 从 StateNotifierProvider 迁移到 NotifierProvider，符合 Riverpod 新推荐写法。
// NotifierProvider 是同步状态，调用方 ref.watch / ref.read(notifier).setXxx 用法完全兼容。
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // 构造时异步加载持久化的偏好，加载完成前先用默认值，避免阻塞首帧
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('theme_mode') ?? 0;
    state = ThemeMode.values[index];
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_mode', mode.index);
  }

  void toggle() {
    final newMode = state == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    setThemeMode(newMode);
  }
}

final accentColorProvider =
    NotifierProvider<AccentColorNotifier, Color>(AccentColorNotifier.new);

class AccentColorNotifier extends Notifier<Color> {
  @override
  Color build() {
    _load();
    return const Color(0xFF005BCB);
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
];
