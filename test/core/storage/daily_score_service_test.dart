import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/daily_score_repository.dart';
import 'package:qnote_flutter/core/storage/daily_score_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/models/daily_score.dart';

/// 日期取「距今 N 天」而不是固定历史日期：`adjustRange` 有 92 天跨度上限，
/// 且校验的是与当前时间的差值，写死年份会让用例随时间失效。
DateTime _ago(int days) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
}

String _agoKey(int days) => _ago(days).toIso8601String().split('T').first;

const String _idPrefix = 'svc-';

DailyScore _seed({
  required DateTime date,
  int total = 88,
  Map<String, int> dims = const {
    'sleep': 90,
    'diet': 70,
    'activity': 65,
    'health': 80,
    'screen': 55,
  },
  String summary = '作息规律',
}) {
  final now = DateTime(2026, 9, 1, 8);
  return DailyScore(
    id: '$_idPrefix${_agoKey(date.day)}-$total',
    date: date,
    totalScore: total,
    dimensionScores: dims,
    summary: summary,
    suggestions: '保持',
    recordCount: 5,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 独占库目录：flutter test 并发跑多个文件却共用同一个 qnote.db，
    // 清表与全表计数会互相看到对方的行（虚拟工作区用例就在写同一张表）
    await databaseFactoryFfi.setDatabasesPath(
      Directory.systemTemp.createTempSync('qnote_daily_scores_svc').path,
    );
  });

  final service = DailyScoreService.instance;
  final repository = DailyScoreRepository();
  late Database db;

  setUp(() async {
    db = await DatabaseHelper.instance.database;
    await db.delete('daily_scores');
    await db.delete('sync_log');
  });

  Future<int> rowCount() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM daily_scores');
    return rows.first['c'] as int;
  }

  Future<List<Map<String, Object?>>> scoreLogs() =>
      db.query('sync_log', where: "table_name = 'daily_scores'");

  group('upsertFromPayload 部分更新', () {
    test('只改饮食分时其余四维与总分全部保留', () async {
      await repository.upsertByDate(_seed(date: _ago(31)));

      final result = await service.upsertFromPayload(
        date: _ago(31),
        dimensionScores: {'diet': 40},
      );

      expect(result.created, isFalse);
      expect(result.saved.totalScore, 88, reason: '未传 totalScore 时总分不能被重置');
      expect(result.saved.dimensionScores, {
        'sleep': 90,
        'diet': 40,
        'activity': 65,
        'health': 80,
        'screen': 55,
      });
      expect(result.saved.summary, '作息规律');
      expect(result.saved.recordCount, 5);
    });

    test('空字符串 summary 不覆盖原有评语', () async {
      await repository.upsertByDate(_seed(date: _ago(32)));
      final result = await service.upsertFromPayload(
        date: _ago(32),
        totalScore: 70,
        summary: '   ',
      );
      expect(result.saved.summary, '作息规律');
      expect(result.saved.totalScore, 70);
    });

    test('新建时补齐五维并用基线分兜底缺失总分', () async {
      final result = await service.upsertFromPayload(
        date: _ago(33),
        dimensionScores: {'diet': 66},
      );
      expect(result.created, isTrue);
      expect(result.saved.totalScore, DailyScoreService.kBaselineScore);
      expect(result.saved.dimensionScores.length, 5);
      expect(result.saved.dimensionScores['diet'], 66);
      expect(result.saved.dimensionScores['sleep'], DailyScoreService.kBaselineScore);
    });

    test('越界分值被钳位且当天仍只有一行', () async {
      await repository.upsertByDate(_seed(date: _ago(34)));
      await service.upsertFromPayload(
        date: _ago(34),
        totalScore: 170,
        dimensionScores: {'screen': -20},
      );

      final rows = await db.query(
        'daily_scores',
        where: 'date = ?',
        whereArgs: [_agoKey(34)],
      );
      expect(rows.length, 1);
      final read = await repository.getByDate(_ago(34));
      expect(read!.totalScore, 100);
      expect(read.dimensionScores['screen'], 0);
    });

    test('单日写入广播当天路径与汇总路径', () async {
      final paths = <String>[];
      void listener(WorkspaceChangeEvent e) => paths.add(e.path);
      WorkspaceEventBus.instance.addListener(listener);
      await service.upsertFromPayload(date: _ago(35), totalScore: 75);
      WorkspaceEventBus.instance.removeListener(listener);

      expect(paths, [
        '/stats/scores/${_agoKey(35)}.json',
        '/stats/daily_scores.json',
      ]);
    });
  });

  group('adjustRange', () {
    Future<void> seedThreeDays() async {
      await repository.upsertByDate(_seed(date: _ago(40)));
      await repository.upsertByDate(_seed(date: _ago(39), total: 95));
      await repository.upsertByDate(_seed(date: _ago(36)));
    }

    test('区间内缺评分的天被跳过且不会被新建', () async {
      await seedThreeDays();

      final result = await service.adjustRange(
        from: _ago(40),
        to: _ago(34),
        spec: const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
      );

      expect(result.scoredDays, 3);
      expect(result.applied, 3);
      expect(result.missingDays, 4);
      expect(await rowCount(), 3, reason: '缺评分的天不得被补造成假记录');
      expect(await repository.getByDate(_ago(38)), isNull);
    });

    test('整体降 5 分后总分与五维同步变化，评语文字不动', () async {
      await seedThreeDays();
      await service.adjustRange(
        from: _ago(40),
        to: _ago(36),
        spec: const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
      );

      final read = await repository.getByDate(_ago(40));
      expect(read!.totalScore, 83);
      expect(read.dimensionScores['sleep'], 85);
      expect(read.summary, '作息规律');
      expect(read.suggestions, '保持');
      expect(read.recordCount, 5);
      expect(
        read.id.startsWith(_idPrefix),
        isTrue,
        reason: '批量调整必须原地更新，不换主键',
      );
    });

    test('触上下限的天数被统计出来', () async {
      await seedThreeDays();
      final result = await service.adjustRange(
        from: _ago(40),
        to: _ago(36),
        spec: const ScoreAdjustSpec(delta: 10, fields: kAllScoreFields),
      );
      expect(result.clamped, 1, reason: '总分 95→100 触界');
      final read = await repository.getByDate(_ago(39));
      expect(read!.totalScore, 100);
      expect(read.dimensionScores['sleep'], 100);
    });

    test('只勾屏幕时其他字段整批不变', () async {
      await seedThreeDays();
      await service.adjustRange(
        from: _ago(40),
        to: _ago(36),
        spec: const ScoreAdjustSpec(setValue: 40, fields: {ScoreField.screen}),
      );

      final read = await repository.getByDate(_ago(40));
      expect(read!.totalScore, 88);
      expect(read.dimensionScores['screen'], 40);
      expect(read.dimensionScores['diet'], 70);
    });

    test('dryRun 给出同样的预览但不写库', () async {
      await seedThreeDays();
      final preview = await service.adjustRange(
        from: _ago(40),
        to: _ago(34),
        spec: const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
        dryRun: true,
      );

      expect(preview.dryRun, isTrue);
      expect(preview.applied, 3);
      expect(preview.preview, '命中 3 天 · 该区间无评分 4 天（不会被改动）');

      final read = await repository.getByDate(_ago(40));
      expect(read!.totalScore, 88, reason: '预览不能改数据');
      final logs = await scoreLogs();
      expect(logs, hasLength(3), reason: '只剩预置时的 3 条，预览不新增日志');
    });

    test('整批只广播一次事件', () async {
      await seedThreeDays();
      var events = 0;
      void listener(WorkspaceChangeEvent e) {
        if (e.path.startsWith('/stats/')) events++;
      }

      WorkspaceEventBus.instance.addListener(listener);
      await service.adjustRange(
        from: _ago(40),
        to: _ago(34),
        spec: const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
      );
      WorkspaceEventBus.instance.removeListener(listener);

      expect(events, 1, reason: '逐天 emit 会引发几十次重复重查');
    });

    test('结果全为零变化时不写库也不广播', () async {
      await seedThreeDays();
      var events = 0;
      void listener(WorkspaceChangeEvent e) => events++;
      WorkspaceEventBus.instance.addListener(listener);

      final result = await service.adjustRange(
        from: _ago(40),
        to: _ago(34),
        spec: const ScoreAdjustSpec(delta: 0, fields: kAllScoreFields),
      );
      WorkspaceEventBus.instance.removeListener(listener);

      expect(result.applied, 0);
      expect(events, 0);
    });

    test('超过跨度上限要求分批', () async {
      await expectLater(
        service.adjustRange(
          from: _ago(200),
          to: _ago(1),
          spec: const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('结束日期早于开始日期时抛错', () async {
      await expectLater(
        service.adjustRange(
          from: _ago(30),
          to: _ago(40),
          spec: const ScoreAdjustSpec(delta: -5, fields: kAllScoreFields),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
