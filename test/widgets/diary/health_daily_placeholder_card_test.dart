import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/providers/health_timeline_provider.dart';
import 'package:qnote_flutter/widgets/diary/health_daily_placeholder_card.dart';

void main() {
  const dateKey = '2026-11-13';
  final date = DateTime(2026, 11, 13);

  Widget buildCard({required bool hasSynced, required bool hasData, double width = 320}) {
    return ProviderScope(
      overrides: [
        healthDayAvailabilityProvider(dateKey).overrideWith((ref) => (hasSynced: hasSynced, hasData: hasData)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: HealthDailyPlaceholderCard(date: date, isToday: true),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('未同步状态展示同步入口且 320pt 不溢出', (tester) async {
    await tester.pumpWidget(buildCard(hasSynced: false, hasData: false));
    await tester.pumpAndSettle();

    expect(find.text('运动健康日结'), findsOneWidget);
    expect(find.text('未同步'), findsOneWidget);
    expect(find.text('点击同步小米运动健康，获取今日步数、睡眠与体征'), findsOneWidget);
    expect(find.text('同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已同步但无数据时提示无数据并可重新同步', (tester) async {
    await tester.pumpWidget(buildCard(hasSynced: true, hasData: false));
    await tester.pumpAndSettle();

    expect(find.text('无数据'), findsOneWidget);
    expect(find.text('已同步，今日没有步数、睡眠或运动记录'), findsOneWidget);
    expect(find.text('重新同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有数据但缺日结卡时提示生成', (tester) async {
    await tester.pumpWidget(buildCard(hasSynced: true, hasData: true));
    await tester.pumpAndSettle();

    expect(find.text('待生成'), findsOneWidget);
    expect(find.text('健康数据已就绪，点击生成日结卡片'), findsOneWidget);
    expect(find.text('生成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
