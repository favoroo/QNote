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

  AiTokenUsage usage(int prompt, int completion) => AiTokenUsage(
        promptTokens: prompt,
        completionTokens: completion,
        totalTokens: prompt + completion,
      );

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
    final threeDaysAgo = AiTokenUsageRepository.dateKeyOf(
      DateTime.now().subtract(const Duration(days: 3)),
    );
    final tenDaysAgo = AiTokenUsageRepository.dateKeyOf(
      DateTime.now().subtract(const Duration(days: 10)),
    );
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
      usage: const AiTokenUsage(
        promptTokens: 0,
        completionTokens: 0,
        totalTokens: 0,
      ),
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

  test('dateKeyOf 输出定宽日期键', () {
    expect(
      AiTokenUsageRepository.dateKeyOf(DateTime(2026, 1, 5, 23, 59)),
      '2026-01-05',
    );
  });
}
