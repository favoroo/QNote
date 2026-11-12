import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';

class AppTheme {
  static const Color primaryDefault = Color(0xFF005BCB);

  /// 全 App 底部面板/弹窗的统一进出场样式。
  ///
  /// Flutter 默认 250ms 线性，和 App 其他转场（强调曲线、起手快收尾缓）不同调；
  /// 这里统一成 [AppCurves.emphasized] 进、[AppCurves.exit] 出，与路由转场同节奏。
  /// 调用点只需 `showModalBottomSheet(..., sheetAnimationStyle: AppTheme.sheetAnimationStyle)`。
  static const AnimationStyle sheetAnimationStyle = AnimationStyle(
    duration: AppDurations.sheet,
    curve: AppCurves.emphasized,
    reverseDuration: AppDurations.normal,
    reverseCurve: AppCurves.exit,
  );

  /// 遵循 Material 3 规范的全局页面转场：
  /// - Android/桌面/Web 采用平滑的向前淡入 (FadeForwards)
  /// - iOS 保持原生平滑滑动手势 (Cupertino)
  static const PageTransitionsTheme _pageTransitionsTheme = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    },
  );

  static ThemeData lightTheme(Color accentColor) => _build(accentColor, AppSurfacePalette.legacyLight);

  static ThemeData darkTheme(Color accentColor) => _build(accentColor, AppSurfacePalette.legacyDark);

  /// 按背景设置构建某一槽位（系统浅色/深色）的主题。
  ///
  /// `MaterialApp` 的 theme/darkTheme 都走这里：
  /// - 跟随系统：两个槽位分别拿到 legacy 浅色/深色主题
  /// - 固定浅色/深色：两个槽位拿到同一套主题，系统切换不改变观感
  /// - OLED/主题色/自定义：两个槽位拿到按画布推导的同一套主题
  static ThemeData build({
    required Color accentColor,
    required AppBackgroundSetting background,
    required Brightness platformBrightness,
  }) {
    final palette = background.resolvePalette(accentColor: accentColor, platformBrightness: platformBrightness);
    return _build(accentColor, palette);
  }

  static ThemeData _build(Color accentColor, AppSurfacePalette palette) {
    final isDark = palette.isDark;
    // 主题色始终使用用户所选的原色：背景可以自由换，但按钮/FAB/开关/复选框/文字图标
    // 都不再被背景「带偏」成过深或过浅的另一套颜色，选什么就显示什么。
    final primary = accentColor;
    final onPrimary = AppContrast.onColor(primary);
    final primaryContainer = primary.withValues(alpha: isDark ? 0.18 : 0.10);
    final onPrimaryContainer = AppContrast.readable(primary, Color.alphaBlend(primaryContainer, palette.surface));

    // legacy 的 secondary/tertiary 是既有视觉的一部分，派生背景则跟随校准后的中性色，
    // 避免固定色在饱和背景上失去对比度
    final secondary = palette.isLegacy
        ? (isDark ? const Color(0xFF8E94A3) : const Color(0xFF5B5F6E))
        : palette.onSurfaceVariant;
    final onSecondary = palette.isLegacy ? (isDark ? const Color(0xFF111318) : Colors.white) : palette.surface;
    final tertiary = isDark ? const Color(0xFF4DD0D0) : const Color(0xFF006A6A);
    final onTertiary = palette.isLegacy
        ? (isDark ? const Color(0xFF111318) : Colors.white)
        : AppContrast.onColor(tertiary);
    final onSecondaryContainer = palette.isLegacy
        ? (isDark ? const Color(0xFFC2C6D6) : const Color(0xFF191B23))
        : palette.onSurface;

    final colorScheme = ColorScheme(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: onSecondary,
      secondaryContainer: palette.surfaceContainerHigh,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: tertiary,
      onTertiary: onTertiary,
      surface: palette.surface,
      onSurface: palette.onSurface,
      surfaceContainerLowest: palette.surfaceContainerLowest,
      surfaceContainerLow: palette.surfaceContainerLow,
      surfaceContainer: palette.surfaceContainer,
      surfaceContainerHigh: palette.surfaceContainerHigh,
      surfaceContainerHighest: palette.surfaceContainerHighest,
      onSurfaceVariant: palette.onSurfaceVariant,
      outline: palette.outline,
      outlineVariant: palette.outlineVariant,
      error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
      onError: isDark ? const Color(0xFF690005) : Colors.white,
      errorContainer: isDark ? const Color(0xFF93000A) : const Color(0xFFFFDAD6),
      onErrorContainer: isDark ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
      inverseSurface: palette.inverseSurface,
      onInverseSurface: palette.onInverseSurface,
      inversePrimary: isDark ? const Color(0xFF0058BE) : const Color(0xFFAAC6FF),
      brightness: palette.brightness,
    );

    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: palette.brightness,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: palette.canvas,
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.onSurface,
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        ),
        titleTextStyle: TextStyle(color: palette.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          // 派生背景下面色可能和画布很接近，补一圈细边交代卡片边界
          side: palette.isLegacy ? BorderSide.none : BorderSide(color: palette.outlineVariant, width: 0.8),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: onPrimary,
        elevation: 2,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: primary,
        unselectedItemColor: palette.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        backgroundColor: palette.surface,
        elevation: 0,
        selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        filled: true,
        fillColor: isDark ? palette.surfaceContainerLow : palette.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: palette.onSurfaceVariant),
        labelStyle: TextStyle(color: palette.onSurfaceVariant, fontSize: 13),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        selectedColor: primary.withValues(alpha: isDark ? 0.2 : 0.15),
        labelStyle: TextStyle(color: palette.onSurface, fontSize: 13),
        side: BorderSide(color: palette.outline),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      dividerTheme: DividerThemeData(color: palette.outlineVariant, thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: primary.withValues(alpha: isDark ? 0.15 : 0.12),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: primary);
          }
          return IconThemeData(color: palette.onSurfaceVariant);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(color: primary, fontSize: 11, fontWeight: FontWeight.w600);
          }
          return TextStyle(color: palette.onSurfaceVariant, fontSize: 11);
        }),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: palette.surface, surfaceTintColor: Colors.transparent),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: palette.onSurfaceVariant)),
      // 浅色 SnackBar 继续用 M3 默认的 inverseSurface；深色改抬升容器色并同步文字色，
      // 否则默认正文仍按 onInverseSurface 绘制，落在深色底上会读不清。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: isDark ? palette.surfaceContainerHighest : null,
        contentTextStyle: isDark
            ? TextStyle(color: palette.onSurface, fontSize: AppTypography.bodyLarge, fontFamily: 'Inter')
            : null,
        actionTextColor: isDark ? primary : null,
        closeIconColor: isDark ? palette.onSurfaceVariant : null,
      ),
      // Tooltip 也按明暗分开：浅色沿用反向浮层，深色统一成抬升表面并补细描边
      tooltipTheme: isDark
          ? TooltipThemeData(
              decoration: BoxDecoration(
                color: palette.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.outlineVariant),
              ),
              textStyle: TextStyle(color: palette.onSurface, fontSize: 12),
            )
          : TooltipThemeData(
              decoration: BoxDecoration(color: palette.inverseSurface, borderRadius: BorderRadius.circular(8)),
              textStyle: TextStyle(color: palette.onInverseSurface, fontSize: 12),
            ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: isDark ? palette.surfaceContainer : palette.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? palette.surfaceContainerLow : palette.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        color: isDark ? palette.surfaceContainer : palette.surface,
        surfaceTintColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return onPrimary;
          }
          return isDark ? palette.onSurfaceVariant : palette.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary;
          }
          return isDark ? palette.outline : palette.surfaceContainerHigh;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(onPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary;
          }
          return palette.onSurfaceVariant;
        }),
      ),
      datePickerTheme: const DatePickerThemeData(
        dayStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
        weekdayStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
        yearStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
      ),
      pageTransitionsTheme: _pageTransitionsTheme,
    );

    if (palette.isLegacy) {
      return theme;
    }
    // Flutter 默认文字色是 black87/white，不跟随 ColorScheme；派生背景必须显式换成
    // 校准过的 onSurface，否则中间亮度背景上普通 Text 会掉到 AA 以下。
    return theme.copyWith(
      textTheme: theme.textTheme.apply(bodyColor: palette.onSurface, displayColor: palette.onSurface),
      iconTheme: IconThemeData(color: palette.onSurface),
    );
  }
}
