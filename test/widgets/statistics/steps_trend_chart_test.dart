import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/health_step_trend.dart';
import 'package:qnote_flutter/widgets/statistics/steps_trend_chart.dart';

Future<void> _pumpChart(
  WidgetTester tester,
  StepTrend trend, {
  double width = 320,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: StepsTrendChart(
                buckets: trend.buckets,
                caption: trend.caption,
                dailyTarget: 8000,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<DateTime, int> _everyDay(DateTime from, DateTime to, int steps) {
  final map = <DateTime, int>{};
  for (var d = from; !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 1)) {
    map[d] = steps;
  }
  return map;
}

void main() {
  testWidgets('月区间在小屏上渲染不溢出，X 轴标签按宽度抽稀', (tester) async {
    final from = DateTime(2026, 2, 1);
    final to = DateTime(2026, 3, 4);
    final trend = buildStepTrend(
      startDate: from,
      endDate: to,
      stepsByDay: _everyDay(from, to, 6000),
    );

    await _pumpChart(tester, trend);

    expect(tester.takeException(), isNull);
    expect(find.text('步数趋势'), findsOneWidget);
    expect(find.text('按天'), findsOneWidget);
    expect(find.text('目标 8,000 步'), findsOneWidget);
    // 32 个日桶在小屏放不下 32 个标签，只保留抽稀后的刻度
    expect(find.text('2/1'), findsOneWidget);
    expect(find.text('2/5'), findsOneWidget);
    expect(find.text('2/2'), findsNothing);
  });

  testWidgets('年区间按月出柱，跨年处标出年份', (tester) async {
    final trend = buildStepTrend(
      startDate: DateTime(2025, 9, 24),
      endDate: DateTime(2026, 9, 25),
      stepsByDay: _everyDay(DateTime(2025, 9, 24), DateTime(2026, 9, 25), 9000),
    );

    await _pumpChart(tester, trend);

    expect(tester.takeException(), isNull);
    expect(trend.buckets.length, 13);
    expect(find.text('按月 · 日均'), findsOneWidget);
    expect(find.text('25年9月'), findsOneWidget);
    expect(find.text('26年1月'), findsOneWidget);
    // 抽稀后不是每个月都有标签
    expect(find.text('10月'), findsNothing);
  });

  testWidgets('宽屏 Web 上柱宽有上限，不会被拉成粗块', (tester) async {
    final from = DateTime(2026, 3, 1);
    final trend = buildStepTrend(
      startDate: from,
      endDate: DateTime(2026, 3, 7),
      stepsByDay: _everyDay(from, DateTime(2026, 3, 7), 12000),
    );

    await _pumpChart(tester, trend, width: 900);

    expect(tester.takeException(), isNull);
    expect(find.text('3/1'), findsOneWidget);
    expect(find.text('3/7'), findsOneWidget);
  });
}
