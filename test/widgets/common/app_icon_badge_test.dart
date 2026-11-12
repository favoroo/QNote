import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';

void main() {
  Future<void> pumpBadge(
    WidgetTester tester, {
    required Color accent,
    Color? backgroundColor,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(accent),
        home: Scaffold(
          body: Center(
            child: AppIconBadge(icon: Icons.person_outline, backgroundColor: backgroundColor, onTap: onTap),
          ),
        ),
      ),
    );
  }

  Material badgeMaterial(WidgetTester tester) =>
      tester.widget<Material>(find.descendant(of: find.byType(AppIconBadge), matching: find.byType(Material)));

  testWidgets('默认铺实心主题色，亮色强调色自动配黑图标', (tester) async {
    const neonGreen = Color(0xFFC5E803);
    await pumpBadge(tester, accent: neonGreen);

    expect(badgeMaterial(tester).color, neonGreen);
    final icon = tester.widget<Icon>(find.byIcon(Icons.person_outline));
    expect(icon.color, AppContrast.darkInk);
    expect(AppContrast.contrastRatio(icon.color!, neonGreen), greaterThanOrEqualTo(AppContrast.minimumTextRatio));
  });

  testWidgets('深色强调色自动配白图标', (tester) async {
    await pumpBadge(tester, accent: const Color(0xFF005BCB));

    final icon = tester.widget<Icon>(find.byIcon(Icons.person_outline));
    expect(icon.color, AppContrast.lightInk);
  });

  testWidgets('自定义底座色也按底座亮度选前景', (tester) async {
    const teal = Color(0xFF006A6A);
    await pumpBadge(tester, accent: const Color(0xFF005BCB), backgroundColor: teal);

    final icon = tester.widget<Icon>(find.byIcon(Icons.person_outline));
    expect(icon.color, AppContrast.onColor(teal));
  });

  testWidgets('传入 onTap 时可响应点击', (tester) async {
    var taps = 0;
    await pumpBadge(tester, accent: const Color(0xFFC5E803), onTap: () => taps++);

    await tester.tap(find.byType(AppIconBadge));
    expect(taps, 1);
  });
}
