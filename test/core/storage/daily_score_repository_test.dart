import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/storage/daily_score_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/daily_score.dart';

/// 本文件用 2020 年的固定历史日期：仓储层不做时间窗口校验，固定日期让断言
/// （id、created_at 是否前进等）常年稳定。库级隔离靠 setUpAll 里的独占库目录。
final DateTime _day0 = DateTime(2020, 9, 1);
DateTime _day(int offset) => DateTime(2020, 9, 1 + offset);

const String _idPrefix = 'repo-';

DailyScore _score({
  required String id,
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
  DateTime? createdAt,
  DateTime? updatedAt,
}) {
  final created = createdAt ?? DateTime(2020, 9, 1, 8);
  return DailyScore(
    id: '$_idPrefix$id',
    date: date,
    totalScore: total,
    dimensionScores: dims,
    summary: summary,
    suggestions: '保持',
    recordCount: 5,
    createdAt: created,
    updatedAt: updatedAt ?? created,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 本文件独占一个库目录：flutter test 并发跑多个文件，而 ffi 默认让它们共用
    // 同一个 qnote.db，两个文件同时清表/数行会互相看到对方的数据
    await databaseFactoryFfi.setDatabasesPath(
      Directory.systemTemp.createTempSync('qnote_daily_scores_repo').path,
    );
  });

  final repo = DailyScoreRepository();
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

  Future<List<Map<String, Object?>>> scoreLogs() => db.query(
    'sync_log',
    where: "table_name = 'daily_scores'",
    orderBy: 'id ASC',
  );

  group('upsertByDate', () {
    test('新日期落库一条并生成同步日志', () async {
      final saved = await repo.upsertByDate(_score(id: 'a1', date: _day(2)));
      expect(saved.id, '${_idPrefix}a1');

      final rows = await db.query(
        'daily_scores',
        where: 'date = ?',
        whereArgs: ['2020-09-03'],
      );
      expect(rows.length, 1);
      expect(
        jsonDecode(rows.first['dimension_scores'] as String),
        {'sleep': 90, 'diet': 70, 'activity': 65, 'health': 80, 'screen': 55},
      );

      final logs = await scoreLogs();
      expect(logs.length, 1);
      expect(logs.first['operation'], 'insert');
      expect(logs.first['record_id'], '${_idPrefix}a1');
      expect(jsonDecode(logs.first['data'] as String), isNotNull);
    });

    test('同日期再写不新增行，且保留 id 与 created_at', () async {
      await repo.upsertByDate(
        _score(
          id: 'keep-me',
          date: _day(3),
          total: 88,
          createdAt: DateTime(2020, 8, 1),
        ),
      );

      final saved = await repo.upsertByDate(
        _score(
          id: 'brand-new-uuid',
          date: _day(3),
          total: 61,
          createdAt: DateTime(2020, 9, 20),
        ),
      );

      final rows = await db.query(
        'daily_scores',
        where: 'date = ?',
        whereArgs: ['2020-09-04'],
      );
      expect(rows.length, 1, reason: '不得像 delete-then-insert 那样多出一行');
      expect(saved.id, '${_idPrefix}keep-me', reason: '主键必须稳定，否则端间同步会分叉');
      expect(saved.createdAt, DateTime(2020, 8, 1), reason: '首次评分时间不能被覆盖');
      expect(saved.totalScore, 61);
      expect(
        saved.updatedAt.isAfter(DateTime(2020, 8, 1)),
        isTrue,
        reason: 'updatedAt 必须前进',
      );
    });

    test('合并后的实体只改目标维度，其余维度按原值写回', () async {
      final existing = _score(id: 'm1', date: _day(4));
      await repo.upsertByDate(existing);

      final merged = Map<String, int>.from(existing.dimensionScores)..['diet'] = 40;
      await repo.upsertByDate(existing.copyWith(dimensionScores: merged));

      final read = await repo.getByDate(_day(4));
      expect(read!.dimensionScores, {
        'sleep': 90,
        'diet': 40,
        'activity': 65,
        'health': 80,
        'screen': 55,
      });
      expect(read.totalScore, 88);
    });
  });

  group('upsertBatch', () {
    test('混合新增与更新时返回值与入参一一对应，日志整批一次写', () async {
      await repo.upsertByDate(_score(id: 'old', date: _day(5), total: 70));

      final batch = [
        _score(id: 'old-again', date: _day(5), total: 65),
        _score(id: 'fresh', date: _day(6), total: 91),
        _score(id: 'fresh2', date: _day(7), total: 50),
      ];
      final saved = await repo.upsertBatch(batch);

      expect(saved.map((s) => s.date), [_day(5), _day(6), _day(7)]);
      expect(saved.first.id, '${_idPrefix}old', reason: '已存在的日期沿用原 id');
      expect(saved[1].id, '${_idPrefix}fresh');
      expect(await rowCount(), 3);

      final logs = await scoreLogs();
      expect(logs.length, 4, reason: '1 次单条 + 3 条批量');
      expect(logs.where((l) => l['operation'] == 'insert').length, 3);
      expect(logs.where((l) => l['operation'] == 'update').length, 1);
    });

    test('空列表直接返回，不写日志', () async {
      expect(await repo.upsertBatch(const []), isEmpty);
      expect(await scoreLogs(), isEmpty);
    });
  });

  group('同日重复行的读取', () {
    Future<void> seedDuplicateRows() async {
      await db.insert(
        'daily_scores',
        _score(
          id: 'stale',
          date: _day(8),
          total: 40,
          createdAt: DateTime(2020, 1, 1),
          updatedAt: DateTime(2020, 1, 1),
        ).toMap(),
      );
      await db.insert(
        'daily_scores',
        _score(
          id: 'fresh-row',
          date: _day(8),
          total: 92,
          createdAt: DateTime(2020, 2, 2),
          updatedAt: DateTime(2020, 2, 2),
        ).toMap(),
      );
    }

    test('getByDate 返回 updated_at 最新的一条', () async {
      await seedDuplicateRows();
      final read = await repo.getByDate(_day(8));
      expect(read!.id, '${_idPrefix}fresh-row');
      expect(read.totalScore, 92);
    });

    test('getLatestByDateRange 每个日期只出一条且按日期升序', () async {
      await seedDuplicateRows();
      await repo.upsertByDate(_score(id: 'other', date: _day(7)));

      final list = await repo.getLatestByDateRange(_day0, _day(9));
      final mine = list.where((s) => s.id.startsWith(_idPrefix)).toList();
      expect(mine.length, 2);
      expect(mine.first.date, _day(7));
      expect(mine.last.id, '${_idPrefix}fresh-row');
    });
  });

  group('deleteByDate', () {
    test('删掉当天全部行并写 delete 日志，不碰其他日期', () async {
      await repo.upsertByDate(_score(id: 'd1', date: _day(10)));
      await repo.upsertByDate(_score(id: 'd2', date: _day(11)));
      await db.insert(
        'daily_scores',
        _score(id: 'dup', date: _day(10)).toMap(),
      );

      final removed = await repo.deleteByDate(_day(10));
      expect(removed, 2, reason: '同日重复行应一并清掉');
      expect(await repo.getByDate(_day(10)), isNull);
      expect(await repo.getByDate(_day(11)), isNotNull);

      final logs = await db.query(
        'sync_log',
        where: "table_name = 'daily_scores' AND operation = 'delete'",
      );
      expect(logs.length, 2);
    });

    test('日期无记录时返回 0 且不写日志', () async {
      expect(await repo.deleteByDate(_day(12)), 0);
      expect(await scoreLogs(), isEmpty);
    });
  });
}
