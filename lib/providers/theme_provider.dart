import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
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

final accentColorProvider = StateNotifierProvider<AccentColorNotifier, Color>((ref) {
  return AccentColorNotifier();
});

class AccentColorNotifier extends StateNotifier<Color> {
  AccentColorNotifier() : super(const Color(0xFF005BCB)) {
    _load();
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
  const Color(0xFF005BCB), // 经典蓝 (Default Blue)
  const Color(0xFF5E5CE6), // 皇家紫 (Royal Indigo)
  const Color(0xFFD32F2F), // 珊瑚红 (Coral Crimson)
  const Color(0xFF006A6A), // 深湖绿 (Lake Teal)
  const Color(0xFF994D00), // 琥珀橙 (Amber Orange)
  const Color(0xFFF43F5E), // 玫瑰粉 (Rose Coral)
  const Color(0xFF10B981), // 薄荷绿 (Mint Emerald)
  const Color(0xFF8B5CF6), // 罗兰紫 (Lavender Violet)
  const Color(0xFF0284C7), // 晴空蓝 (Sky Ocean)
  const Color(0xFF8D6E63), // 摩卡棕 (Mocha Earth)
];
