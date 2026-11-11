import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_token_usage.dart';
import 'package:qnote_flutter/widgets/ai/token_usage_detail_sheet.dart';

/// Token 消耗明细内容测试：锁排行口径、厂商名称解析与空态文案。
///
/// 直接测纯展示组件 [TokenUsageDetailView]，不拉起数据库与 Riverpod，
/// 避免 widget 测试被 sqflite 的 FakeAsync 挂死（见 AGENTS.md 已知坑）。
Widget _wrap(AiTokenUsageDetail detail, {List<AiProvider> providers = const []}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: TokenUsageDetailView(detail: detail, providers: providers),
      ),
    ),
  );
}

AiProvider _provider(String id, String name, List<AiProviderModel> models) {
  final now = DateTime(2026, 1, 1);
  return AiProvider(
    id: id,
    name: name,
    providerType: 'openai',
    baseUrl: 'https://example.com',
    apiKeys: const ['sk-test'],
    models: models,
    createdAt: now,
    updatedAt: now,
  );
}

const _detail = AiTokenUsageDetail(
  period: AiTokenUsagePeriod.all,
  summary: AiTokenUsageSummary(promptTokens: 9000, completionTokens: 3000, totalTokens: 12000, requestCount: 30),
  providers: [
    AiTokenUsageBreakdown(
      providerId: 'p1',
      promptTokens: 6000,
      completionTokens: 2000,
      totalTokens: 8000,
      requestCount: 20,
    ),
    AiTokenUsageBreakdown(
      providerId: 'p2',
      promptTokens: 3000,
      completionTokens: 1000,
      totalTokens: 4000,
      requestCount: 10,
    ),
  ],
  models: [
    AiTokenUsageBreakdown(
      providerId: 'p1',
      modelName: 'm1',
      promptTokens: 4000,
      completionTokens: 1000,
      totalTokens: 5000,
      requestCount: 12,
    ),
    AiTokenUsageBreakdown(
      providerId: 'p1',
      modelName: 'm2',
      promptTokens: 2000,
      completionTokens: 1000,
      totalTokens: 3000,
      requestCount: 8,
    ),
    AiTokenUsageBreakdown(
      providerId: 'p2',
      modelName: 'm3',
      promptTokens: 3000,
      completionTokens: 1000,
      totalTokens: 4000,
      requestCount: 10,
    ),
  ],
);

void main() {
  testWidgets('展示总量、厂商排行与模型排行', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _detail,
        providers: [
          _provider('p1', '甲服务', [AiProviderModel.of('m1', name: '模型一'), AiProviderModel.of('m2', name: '模型二')]),
          _provider('p2', '乙服务', [AiProviderModel.of('m3', name: '模型三')]),
        ],
      ),
    );

    expect(find.text('12K'), findsOneWidget, reason: '总消耗用紧凑格式');
    expect(find.text('30 次请求'), findsOneWidget);
    expect(find.text('输入'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('平均/次'), findsOneWidget);

    expect(find.text('厂商排行'), findsOneWidget);
    expect(find.text('2 项'), findsOneWidget);
    expect(find.text('甲服务'), findsOneWidget);
    expect(find.text('乙服务'), findsOneWidget);
    expect(find.text('8K'), findsOneWidget);
    expect(find.text('4K'), findsNWidgets(2), reason: 'p2 合计与 m3 都是 4K');
    expect(find.text('66.7%'), findsOneWidget);
    expect(find.text('33.3%'), findsNWidgets(2));

    expect(find.text('模型排行'), findsOneWidget);
    expect(find.text('3 项'), findsOneWidget);
    expect(find.text('模型一'), findsOneWidget);
    expect(find.text('模型二'), findsOneWidget);
    expect(find.text('模型三'), findsOneWidget);
    expect(find.text('5K'), findsOneWidget);
    expect(find.text('3K'), findsNWidgets(2), reason: '总览的输出与模型二的用量都是 3K');
    expect(find.text('41.7%'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
  });

  testWidgets('厂商被删除后回退显示 id，模型未知时显示占位', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const AiTokenUsageDetail(
          period: AiTokenUsagePeriod.all,
          summary: AiTokenUsageSummary(totalTokens: 100, requestCount: 1),
          providers: [
            AiTokenUsageBreakdown(
              providerId: 'deleted-provider',
              totalTokens: 100,
              promptTokens: 60,
              completionTokens: 40,
              requestCount: 1,
            ),
          ],
          models: [
            AiTokenUsageBreakdown(
              providerId: 'deleted-provider',
              modelName: '',
              totalTokens: 100,
              promptTokens: 60,
              completionTokens: 40,
              requestCount: 1,
            ),
          ],
        ),
      ),
    );

    expect(find.text('deleted-provider'), findsOneWidget);
    expect(find.text('未知模型'), findsOneWidget);
  });

  testWidgets('该范围无数据时显示对应空态', (tester) async {
    await tester.pumpWidget(_wrap(AiTokenUsageDetail.empty(AiTokenUsagePeriod.today)));

    expect(find.text('今日暂无消耗记录'), findsOneWidget);
    expect(find.text('厂商排行'), findsNothing);
    expect(find.text('模型排行'), findsNothing);
  });

  testWidgets('全部范围无数据时空态不带时间前缀', (tester) async {
    await tester.pumpWidget(_wrap(AiTokenUsageDetail.empty(AiTokenUsagePeriod.all)));

    expect(find.text('暂无消耗记录'), findsOneWidget);
    expect(find.text('全部暂无消耗记录'), findsNothing);
  });
}
