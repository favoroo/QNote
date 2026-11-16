import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/knowledge_graph.dart';
import 'package:qnote_flutter/providers/knowledge_graph_provider.dart';
import 'package:qnote_flutter/widgets/statistics/insight_card.dart';

void main() {
  KgInsight insight() {
    final now = DateTime(2026, 11, 10);
    return KgInsight(
      id: 'i1',
      kind: KgInsightKind.lagged,
      title: '「熬夜」之后更容易出现「头痛」',
      body: '在有记录的 30 个相邻日里，出现「熬夜」的第二天，有 7/10 天出现「头痛」（70%），平时是 20%。',
      score: 5,
      support: 7,
      confidence: 0.7,
      lift: 2.2,
      nodeIds: const ['state:late_sleep', 'entity:headache'],
      evidence: const [
        KgEvidence(
          sourceType: KgSourceType.timeline,
          sourceId: 'r1',
          path: '/timeline/2026-11-10.md',
          snippet: '凌晨一点才睡，第二天头痛',
          occurredDate: '2026-11-10',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  Map<String, dynamic> status({int documents = 10, bool hasSource = true}) {
    return {
      'document_count': documents,
      'has_source_data': hasSource,
      'enabled': true,
      'pending_rule_count': 0,
      'last_scan_at': '2026-11-10T10:00:00.000',
    };
  }

  testWidgets('无洞察且已有图谱时整卡隐藏', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kgInsightsProvider.overrideWith((ref) async => const <KgInsight>[]),
          kgStatusProvider.overrideWith((ref) async => status()),
        ],
        child: const MaterialApp(home: Scaffold(body: InsightCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('关联发现'), findsNothing);
  });

  testWidgets('有源数据但图谱为空时显示建立入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kgInsightsProvider.overrideWith((ref) async => const <KgInsight>[]),
          kgStatusProvider.overrideWith((ref) async => {...status(documents: 0), 'pending_rule_count': -1}),
        ],
        child: const MaterialApp(home: Scaffold(body: InsightCard())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关联发现'), findsOneWidget);
    expect(find.text('建立图谱'), findsOneWidget);
  });

  testWidgets('有洞察时展示标题与支持度，点开可见证据', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kgInsightsProvider.overrideWith((ref) async => [insight()]),
          kgStatusProvider.overrideWith((ref) async => status()),
        ],
        child: const MaterialApp(home: Scaffold(body: InsightCard())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关联发现'), findsOneWidget);
    expect(find.text('「熬夜」之后更容易出现「头痛」'), findsOneWidget);
    expect(find.textContaining('支持 7 天'), findsOneWidget);
    expect(find.textContaining('更新于 11-10 10:00'), findsOneWidget);

    await tester.tap(find.text('「熬夜」之后更容易出现「头痛」'));
    await tester.pumpAndSettle();

    expect(find.textContaining('在有记录的 30 个相邻日里'), findsOneWidget);
    expect(find.textContaining('/timeline/2026-11-10.md'), findsOneWidget);
    expect(find.text('问小Q'), findsOneWidget);
    expect(find.text('不感兴趣'), findsOneWidget);
  });
}
