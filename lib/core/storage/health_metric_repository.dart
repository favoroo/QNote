import 'package:sqflite/sqflite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';

final healthMetricRepositoryProvider = Provider<HealthMetricRepository>((ref) {
  return HealthMetricRepository(DatabaseHelper.instance);
});

class HealthMetricRepository {
  final DatabaseHelper _dbHelper;

  HealthMetricRepository(this._dbHelper);

  Future<Database> get _db async => await _dbHelper.database;

  /// 插入或更新单日汇总数据
  Future<void> upsertDailyMetrics(HealthDailyMetrics metrics) async {
    final db = await _db;
    await db.insert(
      'health_daily_metrics',
      metrics.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取指定日期的汇总数据 (YYYY-MM-DD)
  Future<HealthDailyMetrics?> getDailyMetrics(String date) async {
    final db = await _db;
    final rows = await db.query(
      'health_daily_metrics',
      where: 'date = ?',
      whereArgs: [date],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HealthDailyMetrics.fromMap(rows.first);
  }

  /// 获取日期范围内的汇总数据
  Future<List<HealthDailyMetrics>> getDailyMetricsRange(String startDate, String endDate) async {
    final db = await _db;
    final rows = await db.query(
      'health_daily_metrics',
      where: 'date >= ? AND date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'date ASC',
    );
    return rows.map((r) => HealthDailyMetrics.fromMap(r)).toList();
  }

  /// 获取最近 N 天的数据
  Future<List<HealthDailyMetrics>> getRecentDailyMetrics({int limit = 30}) async {
    final db = await _db;
    final rows = await db.query(
      'health_daily_metrics',
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map((r) => HealthDailyMetrics.fromMap(r)).toList();
  }

  /// 检查某条运动记录 sid 是否已存在
  Future<bool> hasSportRecordBySid(String sid) async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT 1 FROM health_sport_records WHERE sid = ? LIMIT 1',
      [sid],
    );
    return result.isNotEmpty;
  }

  /// 批量插入或替换运动记录
  Future<void> upsertSportRecords(List<HealthSportRecord> records) async {
    if (records.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final r in records) {
      batch.insert(
        'health_sport_records',
        r.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// 查询指定日期的单次运动记录
  Future<List<HealthSportRecord>> getSportRecordsByDate(String date) async {
    final db = await _db;
    final rows = await db.query(
      'health_sport_records',
      where: 'start_time LIKE ?',
      whereArgs: ['$date%'],
      orderBy: 'start_time DESC',
    );
    return rows.map((r) => HealthSportRecord.fromMap(r)).toList();
  }

  /// 分页获取单次运动记录
  Future<List<HealthSportRecord>> getSportRecords({int limit = 50, int offset = 0}) async {
    final db = await _db;
    final rows = await db.query(
      'health_sport_records',
      orderBy: 'start_time DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => HealthSportRecord.fromMap(r)).toList();
  }
}
