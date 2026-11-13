import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/providers/drawer_nav_provider.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 与 app.dart 的 `AppTheme.lightTheme(accentColor)` 用法保持一致，取一个代表性强调色
const Color _accent = Color(0xFF4C6EF5);

/// 抽屉必须挂在 Scaffold 的 `drawer` 槽位，才能拿到与真机一致的全屏约束
Future<GlobalKey<ScaffoldState>> _pumpDrawer(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(900, 1200),
  bool open = true,
  ProviderContainer? container,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final scaffoldKey = GlobalKey<ScaffoldState>();

  final app = MaterialApp(
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
  );

  await tester.pumpWidget(
    container == null ? ProviderScope(child: app) : UncontrolledProviderScope(container: container, child: app),
  );

  if (open) {
    await tester.tap(find.text('open_drawer'));
    await tester.pumpAndSettle();
  }
  return scaffoldKey;
}

/// 点遮罩关闭抽屉：这是「只是想瞄一眼主界面」的典型路径
Future<void> _closeByScrim(WidgetTester tester) async {
  await tester.tapAt(const Offset(880, 600));
  await tester.pumpAndSettle();
}

void main() {
  // 底部版本区读取 AppVersion.version（运行时由 package_info_plus 注入），测试里直接给定
  setUp(() => AppVersion.version = '0.0.0-test');

  group('SideDrawer 排版', () {
    testWidgets('7 个入口全部可见，行与行之间以 6 条分隔线区隔', (tester) async {
      await _pumpDrawer(tester);

      for (final label in <String>['个人信息', '小Q设置', '快捷记录', '数据与同步', '健康数据', '个性化设置', '关于 QNote']) {
        expect(find.text(label), findsOneWidget, reason: '缺少入口：$label');
      }
      // 已合并的旧入口不再单独出现
      expect(find.text('AI 模型配置'), findsNothing);
      expect(find.text('快捷按钮管理'), findsNothing);
      expect(find.text('固定事件管理'), findsNothing);
      expect(find.text('小米运动健康'), findsNothing);
      expect(find.text('屏幕使用时间'), findsNothing);
      expect(find.byType(Divider), findsNWidgets(6));
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
      expect(find.byType(Divider), findsNWidgets(6));
      expect(tester.takeException(), isNull);
    });
  });

  group('SideDrawer 位置记忆', () {
    testWidgets('点遮罩关闭后立刻重开，仍停在刚才的入口页', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final scaffoldKey = await _pumpDrawer(tester, container: container);

      await tester.tap(find.text('个性化设置'));
      await tester.pumpAndSettle();
      // 已进入二级页：菜单项不再可见
      expect(find.text('数据与同步'), findsNothing);

      await _closeByScrim(tester);
      expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
      // 关闭瞬间写入记忆
      expect(container.read(drawerNavMemoryProvider).entryId, 'personalization');
      expect(container.read(drawerNavMemoryProvider).closedAt, isNotNull);

      await tester.tap(find.text('open_drawer'));
      await tester.pumpAndSettle();

      // 重开后直接回到个性化设置，而不是一级菜单
      expect(find.text('数据与同步'), findsNothing);
      expect(find.widgetWithText(AppBar, '个性化设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('返回一级菜单后再关闭，下次打开是一级菜单', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await _pumpDrawer(tester, container: container);

      await tester.tap(find.text('个性化设置'));
      await tester.pumpAndSettle();

      // AppBar 返回箭头 → 回到入口清单
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('数据与同步'), findsOneWidget);

      await _closeByScrim(tester);
      expect(container.read(drawerNavMemoryProvider).entryId, isNull);

      await tester.tap(find.text('open_drawer'));
      await tester.pumpAndSettle();
      expect(find.text('数据与同步'), findsOneWidget);
    });

    testWidgets('超过记忆窗口后重开，回到一级菜单', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 预置一条早已过期的记忆
      container
          .read(drawerNavMemoryProvider)
          .recordClosed(entryId: 'personalization', now: DateTime.now().subtract(kDrawerResumeWindow * 2));

      await _pumpDrawer(tester, container: container);

      expect(find.text('数据与同步'), findsOneWidget);
      expect(find.widgetWithText(AppBar, '个性化设置'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('入口 id 失效（版本升级删过条目）时安全退回菜单', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(drawerNavMemoryProvider).recordClosed(entryId: 'removed-entry');

      await _pumpDrawer(tester, container: container);

      expect(find.text('数据与同步'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('连续开关多次仍稳定停在原入口（不会第二次退回菜单）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await _pumpDrawer(tester, container: container);
      await tester.tap(find.text('个性化设置'));
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        await _closeByScrim(tester);
        expect(container.read(drawerNavMemoryProvider).entryId, 'personalization', reason: '第 ${i + 1} 次关闭');

        await tester.tap(find.text('open_drawer'));
        await tester.pumpAndSettle();
        expect(find.text('个人信息'), findsNothing, reason: '第 ${i + 1} 次重开回到了菜单');
        expect(find.widgetWithText(AppBar, '个性化设置'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
