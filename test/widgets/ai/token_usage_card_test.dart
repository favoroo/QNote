import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_token_usage.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/token_usage_card.dart';

/// Token 消耗卡片测试：锁「空态不吓人」与「有数据时的四个口径都在」。
///
/// 不拉起真实数据库：provider 用 override 直接给值，避免 widget 测试被
/// sqflite 的 FakeAsync 挂死（见 AGENTS.md 的已知坑）。
Widget _wrap(AiTokenUsageSummary summary) {
  return ProviderScope(
    overrides: [
      aiTokenUsageSummaryProvider.overrideWith((ref) async => summary),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: TokenUsageCard(),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('无数据时显示引导文案，不显示数字', (tester) async {
    await tester.pumpWidget(_wrap(AiTokenUsageSummary.empty));
    await tester.pumpAndSettle();

    expect(find.text('Token 消耗'), findsOneWidget);
    expect(find.textContaining('暂无消耗记录'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('有数据时展示总计与输入/输出/今日/近7天', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const AiTokenUsageSummary(
          promptTokens: 12000,
          completionTokens: 3000,
          totalTokens: 15000,
          requestCount: 42,
          todayTokens: 1500,
          weekTokens: 9000,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('15K'), findsOneWidget, reason: '总计用紧凑格式');
    expect(find.text('42 次请求'), findsOneWidget);
    expect(find.text('输入'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('近 7 天'), findsOneWidget);
    expect(find.text('12K'), findsOneWidget);
    expect(find.text('3K'), findsOneWidget);
  });
}
