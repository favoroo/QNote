import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';

/// 与 app.dart 的 `AppTheme.lightTheme(accentColor)` 用法保持一致，取一个代表性强调色
const Color _accent = Color(0xFF4C6EF5);

/// 抽屉必须挂在 Scaffold 的 `drawer` 槽位，才能拿到与真机一致的全屏约束
Future<void> _pumpDrawer(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(900, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final scaffoldKey = GlobalKey<ScaffoldState>();

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.lightTheme(_accent),
        darkTheme: AppTheme.darkTheme(_accent),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
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

  group('SideDrawer 排版', () {
    testWidgets('10 个入口全部可见，行与行之间以 9 条分隔线区隔', (tester) async {
      await _pumpDrawer(tester);

      for (final label in <String>[
        '个人信息',
        '小Q设置',
        'AI 模型配置',
        '快捷按钮管理',
        '固定事件管理',
        '数据与同步',
        '小米运动健康',
        '屏幕使用时间',
        '个性化设置',
        '关于 QNote',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少入口：$label');
      }
      expect(find.byType(Divider), findsNWidgets(9));
      expect(find.textContaining('Version'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('菜单行高放松到 M3 单行标准（约 56），不再被负 visualDensity 压缩', (tester) async {
      await _pumpDrawer(tester);

      final height = tester.getRect(find.byType(ListTile).first).height;
      // 旧版为 48（VisualDensity(vertical: -2)），这里断言已回到 56 上下
      expect(height, greaterThanOrEqualTo(52));
      expect(height, lessThanOrEqualTo(60));
    });

    testWidgets('分隔线左端与菜单文字左缘对齐', (tester) async {
      await _pumpDrawer(tester);

      // Divider 的 indent 由内层 Container 的 margin（Padding 盒）承担，其矩形仍含外边距；
      // 量真正描边的 DecoratedBox 才是那条线的左端。
      final lineRect = tester.getRect(
        find.descendant(of: find.byType(Divider).first, matching: find.byType(DecoratedBox)).first,
      );
      final textLeft = tester.getRect(find.text('小Q设置')).left;
      expect(lineRect.left, closeTo(textLeft, 1.0));
    });

    testWidgets('窄小窗口下可滚动且不溢出生成异常', (tester) async {
      await _pumpDrawer(tester, size: const Size(400, 300));

      expect(find.text('个人信息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色主题下同样完整渲染', (tester) async {
      await _pumpDrawer(tester, brightness: Brightness.dark);

      expect(find.text('个性化设置'), findsOneWidget);
      expect(find.byType(Divider), findsNWidgets(9));
      expect(tester.takeException(), isNull);
    });
  });
}
