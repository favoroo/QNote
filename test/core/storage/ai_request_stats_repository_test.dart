import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/storage/ai_request_stats_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_request_stat.dart';

/// `ai_request_stats` 观测表仓储单测：走真实建表与迁移（DatabaseHelper），不联网。
///
/// 注意本项目 ffi 后端下**所有测试 isolate 共用同一个 qnote.db 文件**，
/// 因此只清理自己这张表，绝不做全库重置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AiRequestStatsRepository repo;

  AiRequestStat stat({
    String outcome = AiRequestOutcomes.ok,
    String scene = '带工具流式对话',
    String modelId = 'deepseek-flash',
    String keyMask = 'sk-a...0001',
    int latencyMs = 1200,
    int? ttftMs,
    DateTime? createdAt,
  }) {
    final at = createdAt ?? DateTime.now();
    return AiRequestStat(
      scene: scene,
      modelId: modelId,
      keyMask: keyMask,
      outcome: outcome,
      latencyMs: latencyMs,
      ttftMs: ttftMs,
      httpStatus: outcome == AiRequestOutcomes.tpm ? 429 : 200,
      promptTokens: 100,
      completionTokens: 20,
      cachedTokens: null,
      createdAt: at,
    );
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
    repo = AiRequestStatsRepository();
  });

  setUp(() async {
    await db.delete(AiRequestStatsRepository.table);
  });

  test('v26 迁移后表结构齐备（缺列会让观测静默失效）', () async {
    final columns = await db.rawQuery(
      'PRAGMA table_info(${AiRequestStatsRepository.table})',
    );
    final names = columns.map((c) => c['name'] as String).toSet();
    expect(
      names,
      containsAll(<String>[
        'id',
        'scene',
        'model_id',
        'key_mask',
        'outcome',
        'http_status',
        'latency_ms',
        'ttft_ms',
        'prompt_tokens',
        'completion_tokens',
        'cached_tokens',
        'hour_bucket',
        'created_at',
      ]),
      reason: '观测表如果只走 onOpen 兜底而列不全，写入会静默失败、面板永远是空的',
    );
  });

  group('写入与读取', () {
    test('record 落库后能被 recent 读回，字段一一对应', () async {
      await repo.record(
        stat(outcome: AiRequestOutcomes.tpm, ttftMs: 800, keyMask: 'sk-b...0002'),
      );

      final rows = await repo.recent(hours: 1);
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row.outcome, equals(AiRequestOutcomes.tpm));
      expect(row.keyMask, equals('sk-b...0002'));
      expect(row.modelId, equals('deepseek-flash'));
      expect(row.scene, equals('带工具流式对话'));
      expect(row.ttftMs, equals(800));
      expect(row.latencyMs, equals(1200));
      expect(row.promptTokens, equals(100));
      expect(row.httpStatus, equals(429));
      // 明文凭证不得入表
      expect(row.keyMask.contains('...'), isTrue);
    });

    test('recent 的时间窗按小时分桶生效，窗口外的行不返回', () async {
      final now = DateTime.now();
      await repo.record(stat(keyMask: 'sk-new...0001'));
      await repo.record(
        stat(keyMask: 'sk-old...0001', createdAt: now.subtract(const Duration(days: 3))),
      );

      final lastHour = await repo.recent(hours: 1);
      expect(lastHour.map((r) => r.keyMask), equals(['sk-new...0001']));

      final lastWeek = await repo.recent(hours: 24 * 4);
      expect(lastWeek, hasLength(2));
    });

    test('空表时 recent 返回空列表而不是抛异常', () async {
      expect(await repo.recent(), isEmpty);
      expect(await repo.count(), equals(0));
    });
  });

  group('裁剪与清空', () {
    test('prune 删掉超过保留天数的行', () async {
      final now = DateTime.now();
      await repo.record(stat(keyMask: 'sk-keep...0001'));
      await repo.record(
        stat(keyMask: 'sk-stale...01', createdAt: now.subtract(
          const Duration(days: AiRequestStatsRepository.keepDays + 1),
        )),
      );

      final deleted = await repo.prune();
      expect(deleted, equals(1));
      final left = await repo.all();
      expect(left.map((r) => r.keyMask), equals(['sk-keep...0001']));
    });

    test('clear 清空全部并返回删除条数', () async {
      await repo.record(stat());
      await repo.record(stat(outcome: AiRequestOutcomes.rps));

      expect(await repo.clear(), equals(2));
      expect(await repo.count(), equals(0));
    });
  });

  group('分桶键', () {
    test('hourBucketOf 定宽补零，字典序即时间序', () {
      final early = AiRequestStat.hourBucketOf(DateTime(2026, 1, 2, 3));
      final later = AiRequestStat.hourBucketOf(DateTime(2026, 9, 25, 11));
      expect(early, equals('2026010203'));
      expect(later.compareTo(early), greaterThan(0));
    });

    test('parseHourBucket 与 hourBucketOf 互逆', () {
      final origin = DateTime(2026, 9, 25, 13);
      expect(
        AiRequestStat.parseHourBucket(AiRequestStat.hourBucketOf(origin)),
        equals(DateTime(2026, 9, 25, 13)),
      );
      expect(AiRequestStat.parseHourBucket('bad'), isNull);
    });
  });

  test('模型行的 hourBucket 缺省时由 createdAt 推导', () {
    final row = stat(createdAt: DateTime(2026, 9, 25, 7));
    expect(row.hourBucket, equals('2026092507'));
    expect(row.isSuccess, isTrue);
    expect(
      stat(outcome: AiRequestOutcomes.rps).isLimited,
      isTrue,
      reason: '限流率的分子要同时含 rps 与额度两类',
    );
  });
}
