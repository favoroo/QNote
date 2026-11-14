import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_surface.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';

/// 用户反馈的场景：把背景设成主题色（同色系荧光黄绿）后，抽屉里的品牌字
/// 「QNote」与底部版本号几乎看不见。这里用真实派生主题渲染抽屉，直接断言对比度。
const Color _lime = Color(0xFFC5E803);

Future<void> _pumpDrawer(WidgetTester tester, ThemeData theme) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final scaffoldKey = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          key: scaffoldKey,
          drawer: const SideDrawer(),
          body: Center(
            child: ElevatedButton(
              onPressed: () => scaffoldKey.currentState!.openDrawer(),
              child: const Text('open_drawer'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open_drawer'));
  await tester.pumpAndSettle();
}

void main() {
  // 底部版本区读取 AppVersion.version（运行时由 package_info_plus 注入），测试里直接给定
  setUp(() => AppVersion.version = '0.0.0-test');

  final theme = AppTheme.build(
    accentColor: _lime,
    background: const AppBackgroundSetting(preset: AppBackgroundPreset.accent),
    platformBrightness: Brightness.light,
  );

  testWidgets('同色系主题色背景下抽屉品牌字与版本号仍可读', (tester) async {
    await _pumpDrawer(tester, theme);

    final surface = theme.colorScheme.surface;

    final title = tester.widget<Text>(find.text('QNote'));
    expect(
      AppContrast.contrastRatio(title.style!.color!, surface),
      greaterThanOrEqualTo(4.5),
      reason: '品牌字「QNote」在同色系背景上应达到正文对比度',
    );

    final version = tester.widget<Text>(
      find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('Version ')),
    );
    expect(
      AppContrast.contrastRatio(Color.alphaBlend(version.style!.color!, surface), surface),
      greaterThanOrEqualTo(3.0),
      reason: '版本号不应淡到看不见',
    );

    // 菜单项箭头（可进入暗示）同样要看得见
    final chevron = tester.widget<Icon>(find.byIcon(Icons.chevron_right).first);
    expect(AppContrast.contrastRatio(Color.alphaBlend(chevron.color!, surface), surface), greaterThanOrEqualTo(2.5));
  });
}
