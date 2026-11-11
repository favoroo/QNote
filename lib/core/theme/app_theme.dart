import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';

class AppTheme {
  static const Color primaryDefault = Color(0xFF005BCB);

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

  static ThemeData lightTheme(Color accentColor) {
    // 主题色由用户自选，可能极亮（如荧光黄绿）；前景色一律按对比度推导，
    // 避免浅色主题色上出现白字压浅底。
    final onPrimary = AppContrast.onColor(accentColor);
    // 强调色当文字时贴的是 surface（白）或半透明 primaryContainer 淡底，
    // 先把淡底合到 surface 上再算，才能得到真实可读的深色。
    final accentOnSurface = AppContrast.readable(accentColor, Colors.white);
    final primaryContainer = accentColor.withValues(alpha: 0.1);
    final onPrimaryContainer = AppContrast.readable(accentColor, Color.alphaBlend(primaryContainer, Colors.white));
    final colorScheme = ColorScheme(
      primary: accentColor,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: const Color(0xFF5B5F6E),
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFECEDEF),
      onSecondaryContainer: const Color(0xFF191B23),
      tertiary: const Color(0xFF006A6A),
      onTertiary: Colors.white,
      surface: Colors.white,
      onSurface: const Color(0xFF191B23),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF9F9FF),
      surfaceContainer: const Color(0xFFF2F3FD),
      surfaceContainerHigh: const Color(0xFFECEDEF),
      surfaceContainerHighest: const Color(0xFFE4E5EC),
      onSurfaceVariant: const Color(0xFF727785),
      outline: const Color(0xFFC2C6D6),
      outlineVariant: const Color(0xFFE4E5EC),
      error: const Color(0xFFBA1A1A),
      onError: Colors.white,
      errorContainer: const Color(0xFFFFDAD6),
      onErrorContainer: const Color(0xFF410002),
      inverseSurface: const Color(0xFF30303C),
      onInverseSurface: const Color(0xFFF2F3FD),
      inversePrimary: const Color(0xFFAAC6FF),
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: Brightness.light,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: const Color(0xFFF9F9FF),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        titleTextStyle: TextStyle(color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentColor,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: accentOnSurface,
        unselectedItemColor: const Color(0xFF727785),
        type: BottomNavigationBarType.fixed,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accentOnSurface, width: 1.5),
        ),
        filled: true,
        fillColor: colorScheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
        labelStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        selectedColor: accentColor.withValues(alpha: 0.15),
        labelStyle: TextStyle(color: colorScheme.onSurface, fontSize: 13),
        side: BorderSide(color: colorScheme.outline),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      dividerTheme: DividerThemeData(color: colorScheme.outlineVariant, thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: accentColor.withValues(alpha: 0.12),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: accentOnSurface);
          }
          return const IconThemeData(color: Color(0xFF727785));
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(color: accentOnSurface, fontSize: 11, fontWeight: FontWeight.w600);
          }
          return const TextStyle(color: Color(0xFF727785), fontSize: 11);
        }),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: colorScheme.surface, surfaceTintColor: Colors.transparent),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentOnSurface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: colorScheme.onSurfaceVariant)),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      // Tooltip 也是浮层，统一成与菜单/卡片一致的小圆角
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: colorScheme.inverseSurface, borderRadius: BorderRadius.circular(8)),
        textStyle: TextStyle(color: colorScheme.onInverseSurface, fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: colorScheme.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        color: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return const Color(0xFFC2C6D6);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentColor;
          }
          return const Color(0xFFECEDEF);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentColor;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(colorScheme.onPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentOnSurface;
          }
          return const Color(0xFF727785);
        }),
      ),
      datePickerTheme: const DatePickerThemeData(
        dayStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
        weekdayStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
        yearStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
      ),
      pageTransitionsTheme: _pageTransitionsTheme,
    );
  }

  static ThemeData darkTheme(Color accentColor) {
    const darkSurface = Color(0xFF1A1D24);
    // 与浅色主题同理：深色模式下强调色当文字时要朝白提亮才读得清；
    // 原先写死的 #A5B4FC 只对蓝色系主题成立。
    final onPrimary = AppContrast.onColor(accentColor);
    final accentOnSurface = AppContrast.readable(accentColor, darkSurface);
    final primaryContainer = accentColor.withValues(alpha: 0.18);
    final onPrimaryContainer = AppContrast.readable(accentColor, Color.alphaBlend(primaryContainer, darkSurface));
    final colorScheme = ColorScheme(
      primary: accentColor,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: const Color(0xFF8E94A3),
      onSecondary: const Color(0xFF111318),
      secondaryContainer: const Color(0xFF2A2D36),
      onSecondaryContainer: const Color(0xFFC2C6D6),
      tertiary: const Color(0xFF4DD0D0),
      onTertiary: const Color(0xFF111318),
      surface: const Color(0xFF1A1D24),
      onSurface: const Color(0xFFE2E2E9),
      surfaceContainerLowest: const Color(0xFF111318),
      surfaceContainerLow: const Color(0xFF1A1D24),
      surfaceContainer: const Color(0xFF22252C),
      surfaceContainerHigh: const Color(0xFF2A2D36),
      surfaceContainerHighest: const Color(0xFF363A45),
      onSurfaceVariant: const Color(0xFF8E94A3),
      outline: const Color(0xFF383C47),
      outlineVariant: const Color(0xFF2A2D36),
      error: const Color(0xFFFFB4AB),
      onError: const Color(0xFF690005),
      errorContainer: const Color(0xFF93000A),
      onErrorContainer: const Color(0xFFFFDAD6),
      inverseSurface: const Color(0xFFE2E2E9),
      onInverseSurface: const Color(0xFF30303C),
      inversePrimary: const Color(0xFF0058BE),
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: const Color(0xFF111318),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        centerTitle: true,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        titleTextStyle: TextStyle(color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentColor,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: accentOnSurface,
        unselectedItemColor: const Color(0xFF8E94A3),
        type: BottomNavigationBarType.fixed,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accentOnSurface, width: 1.5),
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
        labelStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        selectedColor: accentColor.withValues(alpha: 0.2),
        labelStyle: TextStyle(color: colorScheme.onSurface, fontSize: 13),
        side: BorderSide(color: colorScheme.outline),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      dividerTheme: DividerThemeData(color: colorScheme.outlineVariant, thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: accentColor.withValues(alpha: 0.15),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: accentOnSurface);
          }
          return const IconThemeData(color: Color(0xFF8E94A3));
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(color: accentOnSurface, fontSize: 11, fontWeight: FontWeight.w600);
          }
          return const TextStyle(color: Color(0xFF8E94A3), fontSize: 11);
        }),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: colorScheme.surface, surfaceTintColor: Colors.transparent),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentOnSurface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: colorScheme.onSurfaceVariant)),
      // M3 默认把 SnackBar 底色取成 inverseSurface，深色主题下那是近白色。
      // 这里改用抬升一层的容器色，并同步指定文字色：否则默认正文仍按
      // onInverseSurface（深色）绘制，落在深色底上会读不清。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: colorScheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: AppTypography.bodyLarge,
          fontFamily: 'Inter',
        ),
        actionTextColor: colorScheme.primary,
        closeIconColor: colorScheme.onSurfaceVariant,
      ),
      // Tooltip 同样别再走 inverseSurface：深色下浅色气泡会跳成亮斑，
      // 统一成与菜单/卡片一致的抬升表面，并补一圈细描边交代边界。
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        textStyle: TextStyle(color: colorScheme.onSurface, fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: colorScheme.surfaceContainer,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        color: colorScheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return const Color(0xFF8E94A3);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentColor;
          }
          return const Color(0xFF383C47);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentColor;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(colorScheme.onPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentOnSurface;
          }
          return const Color(0xFF8E94A3);
        }),
      ),
      datePickerTheme: const DatePickerThemeData(
        dayStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
        weekdayStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
        yearStyle: TextStyle(height: 1.0, leadingDistribution: TextLeadingDistribution.even),
      ),
      pageTransitionsTheme: _pageTransitionsTheme,
    );
  }
}
