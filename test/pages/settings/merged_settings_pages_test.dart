import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/pages/settings/health_settings_page.dart';
import 'package:qnote_flutter/pages/settings/quick_record_settings_page.dart';
import 'package:qnote_flutter/providers/fixed_event_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/widgets/settings_segment_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 不碰数据库的固定事件 Notifier：综合页测试只关心分段切换，不需要真实模板。
class _FakeFixedEventNotifier extends FixedEventNotifier {
  _FakeFixedEventNotifier(super.ref);

  @override
  Future<void> loadAll() async {}
}

/// 不碰数据库的快捷按钮 Notifier。
class _FakeShortcutNotifier extends ShortcutListNotifier {
  _FakeShortcutNotifier(super.ref);

  @override
  Future<void> load() async {}
}

/// 综合页的子页在 initState 里会查 sqflite；这里用假 Notifier 顶掉，
/// 避免在 FakeAsync 区块里留下 pending timer（会直接判定测试失败）。
Future<void> _pumpQuickRecord(WidgetTester tester, {int initialTab = 0}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fixedEventNotifierProvider.overrideWith(_FakeFixedEventNotifier.new),
        shortcutListNotifierProvider.overrideWith(_FakeShortcutNotifier.new),
      ],
      child: MaterialApp(home: QuickRecordSettingsPage(initialTab: initialTab)),
    ),
  );
  await tester.pump();
}

/// 运动健康子页的 initState 会查 sqflite（账号态、当日指标），
/// 因此整页必须走 ffi 数据库 + runAsync 窗口，否则会无声挂死或抛未初始化。
Future<void> _pumpHealth(WidgetTester tester, {int initialTab = 0}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: HealthSettingsPage(initialTab: initialTab)),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pump();
}

int? _stackIndex(WidgetTester tester) => tester.widget<IndexedStack>(find.byType(IndexedStack)).index;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.instance.database;
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SettingsSegmentBar', () {
    testWidgets('按 items 等分排布，点击非当前项才触发 onChanged', (tester) async {
      final changes = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsSegmentBar(
              items: const [
                SettingsSegmentItem(title: '甲', icon: Icons.circle_outlined),
                SettingsSegmentItem(title: '乙', icon: Icons.square_outlined),
              ],
              selectedIndex: 0,
              onChanged: changes.add,
            ),
          ),
        ),
      );

      final firstCenter = tester.getRect(find.text('甲')).center.dx;
      final secondCenter = tester.getRect(find.text('乙')).center.dx;
      expect((secondCenter - firstCenter).abs(), greaterThan(100));

      // 点已选中的项：不重复回调，避免上层做无意义的 setState
      await tester.tap(find.text('甲'));
      await tester.pump();
      expect(changes, isEmpty);

      await tester.tap(find.text('乙'));
      await tester.pump();
      expect(changes, [1]);
      expect(tester.takeException(), isNull);
    });
  });

  group('QuickRecordSettingsPage', () {
    testWidgets('默认停在快捷按钮分段，可切到固定事件分段', (tester) async {
      await _pumpQuickRecord(tester);

      expect(find.widgetWithText(AppBar, '快捷记录'), findsOneWidget);
      expect(find.text('快捷按钮'), findsOneWidget);
      expect(find.text('固定事件'), findsOneWidget);
      expect(_stackIndex(tester), 0);

      await tester.tap(find.text('固定事件'));
      await tester.pump();
      expect(_stackIndex(tester), 1);
    });

    testWidgets('initialTab 可直接定位到固定事件分段', (tester) async {
      await _pumpQuickRecord(tester, initialTab: 1);
      expect(_stackIndex(tester), 1);
    });

    testWidgets('顶栏「+」随分段切换新建对象', (tester) async {
      await _pumpQuickRecord(tester);

      // 快捷按钮分段：新建按钮 tooltip 指向快捷按钮
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add)).tooltip, '新建快捷按钮');

      await tester.tap(find.text('固定事件'));
      await tester.pump();
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add)).tooltip, '新建固定事件');
    });
  });

  group('HealthSettingsPage', () {
    testWidgets('默认停在运动健康分段，可切到屏幕使用分段', (tester) async {
      await _pumpHealth(tester);

      expect(find.widgetWithText(AppBar, '健康数据'), findsOneWidget);
      expect(find.text('运动健康'), findsOneWidget);
      expect(find.text('屏幕使用'), findsOneWidget);
      expect(_stackIndex(tester), 0);

      await tester.tap(find.text('屏幕使用'));
      await tester.pump();
      expect(_stackIndex(tester), 1);
    });

    testWidgets('initialTab 可直接定位到屏幕使用分段', (tester) async {
      await _pumpHealth(tester, initialTab: 1);
      expect(_stackIndex(tester), 1);
    });
  });
}
