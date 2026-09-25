import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/statistics/date_navigation_header.dart';

/// 日期导航条测试。
///
/// 这个组件从评分 tab 抽出后被评分与屏幕时长共用，一旦行为漂移会同时
/// 影响两个页面，所以把「未来不可选」「回调已归一化到 00:00」「整条高度」
/// 这三条锁住。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 「今天」胶囊的可点击节点（Key 就打在 InkWell 上，文本在其内的 Ink 里）
  final todayPill = find.byKey(const ValueKey('date_nav_today_pill'));

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
        // 用远离今天的过去日期：右箭头本就可点，禁用后必须变灰；
        // 同时胶囊会出现，验证它只是置灰而非消失（避免宽度跳动）
        selectedDate: DateTime(2020, 1, 1),
        onDateChanged: (_) {},
        enabled: false,
      ),
    ));

    expect(navButton(tester, Icons.chevron_left).onPressed, isNull);
    expect(navButton(tester, Icons.chevron_right).onPressed, isNull);
    expect(find.byKey(const ValueKey('date_nav_today_text')), findsOneWidget);
    expect(tester.widget<InkWell>(todayPill).onTap, isNull);
  });

  testWidgets('点「今天」胶囊把日期设为今天 00:00', (tester) async {
    DateTime? changed;
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 1, 1),
        onDateChanged: (date) => changed = date,
      ),
    ));

    await tester.tap(todayPill);
    await tester.pump();
    final now = DateTime.now();
    expect(changed, DateTime(now.year, now.month, now.day));
  });

  testWidgets('选中日期不是今天时显示「今天」胶囊', (tester) async {
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 1, 1),
        onDateChanged: (_) {},
      ),
    ));

    expect(find.byKey(const ValueKey('date_nav_today_text')), findsOneWidget);
  });

  testWidgets('已选中今天时不显示「今天」胶囊', (tester) async {
    final today = DateTime.now();
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(today.year, today.month, today.day),
        onDateChanged: (_) {},
      ),
    ));

    expect(find.byKey(const ValueKey('date_nav_today_text')), findsNothing);
  });

  testWidgets('整条收进单行 48 高，不再挤占内容空间', (tester) async {
    await tester.pumpWidget(wrap(
      DateNavigationHeader(
        selectedDate: DateTime(2026, 1, 1),
        onDateChanged: (_) {},
      ),
    ));

    expect(tester.getRect(find.byType(DateNavigationHeader)).height, 48);
  });

  test('formatDayLabel 覆盖今天/昨天/前天与完整日期', () {
    final today = DateTime(2026, 9, 19);
    expect(formatDayLabel(today, today: today), '今天');
    expect(formatDayLabel(DateTime(2026, 9, 18), today: today), '昨天');
    expect(formatDayLabel(DateTime(2026, 9, 17), today: today), '前天');
    expect(formatDayLabel(DateTime(2026, 9, 16), today: today), '2026年9月16日');
  });
}
