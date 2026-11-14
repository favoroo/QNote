import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/bottom_nav_bar.dart';

void main() {
  Widget wrapNavBar(ThemeData theme, {int currentIndex = ShellBranch.diary}) {
    return ProviderScope(
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          bottomNavigationBar: BottomNavBar(
            currentIndex: currentIndex,
            lastRecordsBranch: ShellBranch.notes,
            onTap: (_) {},
            onQTap: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('同色主题色背景下选中图标切到高对比正文色与柔和胶囊，不比未选中更淡', (tester) async {
    const accent = Color(0xFFC5E803);
    final theme = AppTheme.build(
      accentColor: accent,
      background: const AppBackgroundSetting(preset: AppBackgroundPreset.accent),
      platformBrightness: Brightness.light,
    );

    await tester.pumpWidget(wrapNavBar(theme, currentIndex: ShellBranch.diary));
    await tester.pumpAndSettle();

    final selectedIcon = tester.widget<Icon>(find.byIcon(Icons.book));
    final unselectedIcon = tester.widget<Icon>(find.byIcon(Icons.note_outlined));

    expect(selectedIcon.color, theme.colorScheme.onSurface);
    expect(
      AppContrast.contrastRatio(selectedIcon.color!, theme.colorScheme.surface),
      greaterThan(AppContrast.contrastRatio(unselectedIcon.color!, theme.colorScheme.surface)),
    );
  });

  testWidgets('经典浅色主题下选中图标保持使用主题色 primary', (tester) async {
    final theme = AppTheme.lightTheme(AppTheme.primaryDefault);

    await tester.pumpWidget(wrapNavBar(theme, currentIndex: ShellBranch.diary));
    await tester.pumpAndSettle();

    final selectedIcon = tester.widget<Icon>(find.byIcon(Icons.book));
    final unselectedIcon = tester.widget<Icon>(find.byIcon(Icons.note_outlined));

    expect(selectedIcon.color, theme.colorScheme.primary);
    expect(unselectedIcon.color, theme.colorScheme.onSurfaceVariant);
  });
}
