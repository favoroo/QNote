import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/ai_token_usage_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_token_usage.dart';

/// Token 用量按日聚合仓储测试。
///
/// 锁的是累加语义：同一模型同一天的多次请求必须相加而不是覆盖（否则重度使用
/// 反而显示得比轻度使用少），以及今日 / 近 7 天两个窗口的边界。
void main() {
  late Database db;
  final repo = AiTokenUsageRepository.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 走 DatabaseHelper 建库，顺带验证 v28 的 DDL 真能建出表
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete(AiTokenUsageRepository.table);
  });

  AiTokenUsage usage(int prompt, int completion) =>
      AiTokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion);

  Future<void> insertDay(String date, int total) async {
    await db.insert(AiTokenUsageRepository.table, {
      'date': date,
      'provider_id': 'p1',
      'model_name': 'm1',
      'prompt_tokens': total ~/ 2,
      'completion_tokens': total ~/ 2,
      'total_tokens': total,
      'request_count': 1,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> insertUsage({
    required String date,
    required String providerId,
    required String modelName,
    required int prompt,
    required int completion,
    required int requests,
  }) async {
    await db.insert(AiTokenUsageRepository.table, {
      'date': date,
      'provider_id': providerId,
      'model_name': modelName,
      'prompt_tokens': prompt,
      'completion_tokens': completion,
      'total_tokens': prompt + completion,
      'request_count': requests,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  test('同一天同一模型累加而非覆盖', () async {
    await repo.record(providerId: 'p1', modelName: 'm1', usage: usage(100, 50));
    await repo.record(providerId: 'p1', modelName: 'm1', usage: usage(200, 80));

    final summary = await repo.getSummary();
    expect(summary.promptTokens, 300);
    expect(summary.completionTokens, 130);
    expect(summary.totalTokens, 430);
    expect(summary.requestCount, 2);
  });

  test('不同模型分行统计，总计合并', () async {
    await repo.record(providerId: 'p1', modelName: 'm1', usage: usage(10, 10));
    await repo.record(providerId: 'p2', modelName: 'm2', usage: usage(20, 20));

    final summary = await repo.getSummary();
    expect(summary.totalTokens, 60);
    expect(summary.requestCount, 2);
  });

  test('今日与近 7 天窗口分别聚合', () async {
    final today = AiTokenUsageRepository.dateKeyOf(DateTime.now());
    final threeDaysAgo = AiTokenUsageRepository.dateKeyOf(DateTime.now().subtract(const Duration(days: 3)));
    final tenDaysAgo = AiTokenUsageRepository.dateKeyOf(DateTime.now().subtract(const Duration(days: 10)));
    await insertDay(today, 100);
    await insertDay(threeDaysAgo, 200);
    await insertDay(tenDaysAgo, 400);

    final summary = await repo.getSummary();
    expect(summary.todayTokens, 100);
    expect(summary.weekTokens, 300, reason: '近 7 天含今天，10 天前的不计入');
    expect(summary.totalTokens, 700, reason: '累计不受窗口限制');
  });

  test('零用量不写行', () async {
    await repo.record(
      providerId: 'p1',
      modelName: 'm1',
      usage: const AiTokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
    );

    final summary = await repo.getSummary();
    expect(summary.hasData, isFalse);
    expect(summary.requestCount, 0);
  });

  test('空表返回空汇总', () async {
    final summary = await repo.getSummary();
    expect(summary.hasData, isFalse);
    expect(summary.totalTokens, 0);
  });

  test('明细按时间范围聚合，并按厂商 / 模型降序排行', () async {
    final today = AiTokenUsageRepository.dateKeyOf(DateTime.now());
    final threeDaysAgo = AiTokenUsageRepository.dateKeyOf(DateTime.now().subtract(const Duration(days: 3)));
    final tenDaysAgo = AiTokenUsageRepository.dateKeyOf(DateTime.now().subtract(const Duration(days: 10)));
    final fortyDaysAgo = AiTokenUsageRepository.dateKeyOf(DateTime.now().subtract(const Duration(days: 40)));

    // p1 同厂商两个模型：厂商维度必须折叠成 150，而不是只取最大模型
    await insertUsage(date: today, providerId: 'p1', modelName: 'm1', prompt: 60, completion: 40, requests: 2);
    await insertUsage(date: today, providerId: 'p1', modelName: 'm2', prompt: 30, completion: 20, requests: 1);
    await insertUsage(date: threeDaysAgo, providerId: 'p2', modelName: 'm3', prompt: 120, completion: 80, requests: 4);
    await insertUsage(date: tenDaysAgo, providerId: 'p2', modelName: 'm3', prompt: 240, completion: 160, requests: 8);
    await insertUsage(
      date: fortyDaysAgo,
      providerId: 'p3',
      modelName: 'm4',
      prompt: 480,
      completion: 320,
      requests: 16,
    );

    final todayDetail = await repo.getDetail(AiTokenUsagePeriod.today);
    expect(todayDetail.period, AiTokenUsagePeriod.today);
    expect(todayDetail.summary.totalTokens, 150);
    expect(todayDetail.summary.promptTokens, 90);
    expect(todayDetail.summary.completionTokens, 60);
    expect(todayDetail.summary.requestCount, 3);
    expect(todayDetail.averagePerRequest, 50);
    expect(todayDetail.providers.single.providerId, 'p1');
    expect(todayDetail.providers.single.totalTokens, 150);
    expect(todayDetail.providers.single.requestCount, 3);
    expect(todayDetail.models.map((item) => item.modelName), ['m1', 'm2'], reason: '模型排行按 token 降序');
    expect(todayDetail.models.first.totalTokens, 100);
    expect(todayDetail.models.first.requestCount, 2);

    final week = await repo.getDetail(AiTokenUsagePeriod.week);
    expect(week.summary.totalTokens, 350, reason: '今日 150 + 3 天前 200');
    expect(week.providers.map((item) => item.providerId), ['p2', 'p1'], reason: '厂商排行按 token 降序，200 > 150');
    expect(week.providers.first.requestCount, 4);

    final month = await repo.getDetail(AiTokenUsagePeriod.month);
    expect(month.summary.totalTokens, 750, reason: '近 30 天含 10 天前，不含 40 天前');
    expect(month.providers.first.providerId, 'p2');
    expect(month.providers.first.totalTokens, 600);
    expect(month.providers.first.requestCount, 12);

    final all = await repo.getDetail(AiTokenUsagePeriod.all);
    expect(all.summary.totalTokens, 1550);
    expect(all.providers.map((item) => item.providerId), ['p3', 'p2', 'p1']);
    expect(all.models.length, 4);
  });

  test('明细空表退化为空态而不是抛错', () async {
    final detail = await repo.getDetail(AiTokenUsagePeriod.all);
    expect(detail.hasData, isFalse);
    expect(detail.providers, isEmpty);
    expect(detail.models, isEmpty);
    expect(detail.averagePerRequest, 0);
  });

  test('dateKeyOf 输出定宽日期键', () {
    expect(AiTokenUsageRepository.dateKeyOf(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
  });
}
