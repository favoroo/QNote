import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/statistics/date_navigation_header.dart';

/// 日期导航头测试。
///
/// 这个组件从评分 tab 抽出后被评分与屏幕时长共用，一旦行为漂移会同时
/// 影响两个页面，所以把「未来不可选」「回调已归一化到 00:00」这两条锁住。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  IconButton navButton(WidgetTester tester, IconData icon) {
    return tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(icon),
        matching: find.byType(IconButton),
      ),
    );
  }

  testWidgets('左右箭头按天移动日期', (tester) async {
    DateTime? changed;
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        // 用远离今天的日期，避免右箭头因「不能超过今天」而被禁用
        selectedDate: DateTime(2026, 3, 10),
        onDateChanged: (date) => changed = date,
      ),
    ));

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(changed, DateTime(2026, 3, 9));

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(changed, DateTime(2026, 3, 11));
  });

  testWidgets('传入带时分秒的日期时，回调归一化到当日 00:00', (tester) async {
    DateTime? changed;
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 9, 19, 14, 30),
        onDateChanged: (date) => changed = date,
      ),
    ));

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();

    expect(changed, DateTime(2026, 9, 18));
  });

  testWidgets('已到今天的日期禁止向右切换', (tester) async {
    final today = DateTime.now();
    final todayNoon = DateTime(today.year, today.month, today.day, 12);
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: todayNoon,
        onDateChanged: (_) {},
      ),
    ));

    final next = navButton(tester, Icons.chevron_right);
    expect(next.onPressed, isNull);
  });

  testWidgets('enabled 为 false 时整条禁用', (tester) async {
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 9, 10),
        onDateChanged: (_) {},
        enabled: false,
      ),
    ));

    expect(navButton(tester, Icons.chevron_left).onPressed, isNull);
    expect(navButton(tester, Icons.chevron_right).onPressed, isNull);
  });

  testWidgets('快捷胶囊把日期设为今天/昨天/前天', (tester) async {
    DateTime? changed;
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 1, 1),
        onDateChanged: (date) => changed = date,
      ),
    ));

    await tester.tap(find.widgetWithText(OutlinedButton, '今天'));
    await tester.pump();
    final now = DateTime.now();
    expect(changed, DateTime(now.year, now.month, now.day));

    await tester.tap(find.widgetWithText(OutlinedButton, '前天'));
    await tester.pump();
    expect(changed, DateTime(now.year, now.month, now.day).subtract(const Duration(days: 2)));
  });

  testWidgets('当前选中日的胶囊处于选中态', (tester) async {
    final today = DateTime.now();
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(today.year, today.month, today.day),
        onDateChanged: (_) {},
      ),
    ));

    final button = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '今天'));
    expect(button.style?.backgroundColor, isNotNull);
  });

  testWidgets('showQuickDates 为 false 时隐藏胶囊行', (tester) async {
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 9, 19),
        onDateChanged: (_) {},
        showQuickDates: false,
      ),
    ));

    expect(find.widgetWithText(OutlinedButton, '今天'), findsNothing);
  });

  test('formatDayLabel 覆盖今天/昨天/前天与完整日期', () {
    final today = DateTime(2026, 9, 19);
    expect(formatDayLabel(today, today: today), '今天');
    expect(formatDayLabel(DateTime(2026, 9, 18), today: today), '昨天');
    expect(formatDayLabel(DateTime(2026, 9, 17), today: today), '前天');
    expect(formatDayLabel(DateTime(2026, 9, 16), today: today), '2026年9月16日');
  });
}
