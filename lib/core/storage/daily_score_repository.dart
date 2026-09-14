import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/daily_score.dart';

class DailyScoreRepository {
  static final DailyScoreRepository _instance = DailyScoreRepository._internal();
  factory DailyScoreRepository() => _instance;
  DailyScoreRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  Future<DailyScore?> getByDate(DateTime date) async {
    final db = await _dbHelper.database;
    final dateStr = date.toIso8601String().split('T').first;
    final maps = await db.query(
      'daily_scores',
      where: 'date = ?',
      whereArgs: [dateStr],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DailyScore.fromMap(maps.first);
  }

  Future<List<DailyScore>> getByDateRange(DateTime start, DateTime end) async {
    final db = await _dbHelper.database;
    final startStr = start.toIso8601String().split('T').first;
    final endStr = end.toIso8601String().split('T').first;
    final maps = await db.query(
      'daily_scores',
      where: 'date >= ? AND date <= ?',
      whereArgs: [startStr, endStr],
      orderBy: 'date DESC',
    );
    return maps.map((m) => DailyScore.fromMap(m)).toList();
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
