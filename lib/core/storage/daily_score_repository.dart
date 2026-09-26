import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/daily_score.dart';

class DailyScoreRepository {
  static final DailyScoreRepository _instance = DailyScoreRepository._internal();
  factory DailyScoreRepository() => _instance;
  DailyScoreRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  /// `date` 列的存储格式（与 [DailyScore.toMap] 保持一致）
  static String _dateKey(DateTime date) => date.toIso8601String().split('T').first;

  Future<DailyScore?> getByDate(DateTime date) async {
    final db = await _dbHelper.database;
    final dateStr = _dateKey(date);
    final maps = await db.query(
      'daily_scores',
      where: 'date = ?',
      whereArgs: [dateStr],
      // 无 UNIQUE 约束，同步合并旁路按 id 去重，同一天可能残留多行；
      // 不加 orderBy 时 limit 1 返回哪条不确定，界面会随机显示旧分数
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DailyScore.fromMap(maps.first);
  }

  Future<List<DailyScore>> getByDateRange(DateTime start, DateTime end) async {
    final db = await _dbHelper.database;
    final startStr = _dateKey(start);
    final endStr = _dateKey(end);
    final maps = await db.query(
      'daily_scores',
      where: 'date >= ? AND date <= ?',
      whereArgs: [startStr, endStr],
      orderBy: 'date DESC',
    );
    return maps.map((m) => DailyScore.fromMap(m)).toList();
  }

  /// 范围查询，按日期**升序**且每个日期只出一条（同日多行时取 updated_at 最新）。
  Future<List<DailyScore>> getLatestByDateRange(DateTime start, DateTime end) async {
    final all = await getByDateRange(start, end);
    final latestByDate = <String, DailyScore>{};
    for (final score in all) {
      final key = _dateKey(score.date);
      final current = latestByDate[key];
      if (current == null || score.updatedAt.isAfter(current.updatedAt)) {
        latestByDate[key] = score;
      }
    }
    return latestByDate.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  /// 按日期落一条评分：当天已有记录则沿用其 id 与 created_at 原地更新，
  /// 不像 delete-then-insert 那样丢主键和首次评分时间。
  Future<DailyScore> upsertByDate(DailyScore score) async {
    final saved = await upsertBatch([score]);
    return saved.first;
  }

  /// 单事务批量按日期落库，返回值与 [scores] 一一对应。
  ///
  /// 同步日志整批一次写，避免逐条 insert 拖长事务；漏写日志会让 WebDAV
  /// 对端同步不到改分结果，造成静默数据分叉。
  Future<List<DailyScore>> upsertBatch(List<DailyScore> scores) async {
    if (scores.isEmpty) return const [];
    final db = await _dbHelper.database;
    final saved = <DailyScore>[];
    final logs = <SyncLogEntry>[];
    await db.transaction((txn) async {
      for (final score in scores) {
        final maps = await txn.query(
          'daily_scores',
          where: 'date = ?',
          whereArgs: [_dateKey(score.date)],
          orderBy: 'updated_at DESC',
          limit: 1,
        );
        final DailyScore row;
        final String operation;
        if (maps.isEmpty) {
          row = score;
          operation = 'insert';
          await txn.insert('daily_scores', row.toMap());
        } else {
          final existing = DailyScore.fromMap(maps.first);
          row = score.copyWith(
            id: existing.id,
            createdAt: existing.createdAt,
            updatedAt: DateTime.now(),
          );
          operation = 'update';
          await txn.update(
            'daily_scores',
            row.toMap(),
            where: 'id = ?',
            whereArgs: [row.id],
          );
        }
        saved.add(row);
        logs.add(
          SyncLogEntry(
            tableName: 'daily_scores',
            recordId: row.id,
            operation: operation,
            data: row.toMap(),
            timestamp: DateTime.now(),
          ),
        );
      }
    });
    await _syncLog.logChanges(logs);
    return saved;
  }

  /// 删除某天的评分，返回实际删除行数（大于 1 说明该库存在同日重复行）。
  Future<int> deleteByDate(DateTime date) async {
    final db = await _dbHelper.database;
    final dateStr = _dateKey(date);
    final maps = await db.query(
      'daily_scores',
      where: 'date = ?',
      whereArgs: [dateStr],
      columns: ['id'],
    );
    if (maps.isEmpty) return 0;
    final ids = maps.map((m) => m['id'] as String).toList();
    await db.delete(
      'daily_scores',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    await _syncLog.logChanges(
      ids
          .map(
            (id) => SyncLogEntry(
              tableName: 'daily_scores',
              recordId: id,
              operation: 'delete',
              timestamp: DateTime.now(),
            ),
          )
          .toList(),
    );
    return ids.length;
  }

  Future<DailyScore> insert(DailyScore score) async {
    final db = await _dbHelper.database;
    await db.insert('daily_scores', score.toMap());
    await _syncLog.logChange(
      tableName: 'daily_scores',
      recordId: score.id,
      operation: 'insert',
      data: score.toMap(),
    );
    return score;
  }

  Future<DailyScore> update(DailyScore score) async {
    final db = await _dbHelper.database;
    final updated = score.copyWith(updatedAt: DateTime.now());
    await db.update(
      'daily_scores',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [score.id],
    );
    await _syncLog.logChange(
      tableName: 'daily_scores',
      recordId: score.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('daily_scores', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'daily_scores',
      recordId: id,
      operation: 'delete',
    );
  }
}
