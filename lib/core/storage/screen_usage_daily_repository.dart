import 'package:sqflite/sqflite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';

final screenUsageDailyRepositoryProvider = Provider<ScreenUsageDailyRepository>(
  (ref) {
    return ScreenUsageDailyRepository(DatabaseHelper.instance);
  },
);

/// 每日屏幕时长快照仓储
///
/// 快照是可再生的派生数据（原生 UsageStats 随时可重读），因此不写 sync_log，
/// 与 health_daily_metrics 的处理保持一致。
class ScreenUsageDailyRepository {
  static const String table = 'screen_usage_daily';

  final DatabaseHelper _dbHelper;

  ScreenUsageDailyRepository(this._dbHelper);

  Future<Database> get _db async => await _dbHelper.database;

  /// 幂等写入单日快照，返回总时长是否前进（写入了更大的值）。
  ///
  /// 必须用 MAX 合并而不是 ConflictAlgorithm.replace：系统 UsageStats 的每日
  /// bucket 会滚动淘汰，同一天越晚读到的数值可能反而更小，直接覆盖会让历史
  /// 柱状图随时间倒退。
  Future<bool> upsertSnapshot(ScreenUsageDaily snapshot) async {
    final changed = await upsertSnapshots([snapshot]);
    return changed.isNotEmpty && changed.first;
  }

  /// 批量幂等写入（回填多天时用同一事务，避免逐条开事务）
  /// 返回值与入参一一对应，表示该日总时长是否被更新。
  Future<List<bool>> upsertSnapshots(List<ScreenUsageDaily> snapshots) async {
    if (snapshots.isEmpty) {
      return const [];
    }
    final db = await _db;
    final results = <bool>[];
    await db.transaction((txn) async {
      for (final snapshot in snapshots) {
        results.add(await _mergeOne(txn, snapshot));
      }
    });
    return results;
  }

  Future<bool> _mergeOne(Transaction txn, ScreenUsageDaily snapshot) async {
    final rows = await txn.query(
      table,
      where: 'date = ?',
      whereArgs: [snapshot.date],
      limit: 1,
    );
    final now = DateTime.now().toIso8601String();

    if (rows.isEmpty) {
      await txn.insert(table, snapshot.toMap());
      return snapshot.totalTimeMs > 0;
    }

    final existing = ScreenUsageDaily.fromMap(
      Map<String, dynamic>.from(rows.first),
    );
    final totalAdvanced = snapshot.totalTimeMs > existing.totalTimeMs;

    // 明细只在新快照确实更全时替换：总时长前进、或旧明细缺失
    final appsReplaced =
        snapshot.topApps.isNotEmpty &&
        (totalAdvanced || existing.topApps.isEmpty);

    if (!totalAdvanced && !appsReplaced) {
      // 唯一仍要写的情形：完成标记只能从 0 变 1，不回退
      if (!existing.isComplete && snapshot.isComplete) {
        await txn.update(
          table,
          {'is_complete': 1, 'updated_at': now},
          where: 'date = ?',
          whereArgs: [snapshot.date],
        );
      }
      return false;
    }

    final merged = ScreenUsageDaily(
      date: snapshot.date,
      totalTimeMs: totalAdvanced ? snapshot.totalTimeMs : existing.totalTimeMs,
      topApps: appsReplaced ? snapshot.topApps : existing.topApps,
      isComplete: existing.isComplete || snapshot.isComplete,
      source: totalAdvanced ? snapshot.source : existing.source,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    final values = merged.toMap()..remove('created_at');
    await txn.update(
      table,
      values,
      where: 'date = ?',
      whereArgs: [snapshot.date],
    );
    return totalAdvanced;
  }

  /// 读取指定日期（YYYY-MM-DD）的快照，无记录返回 null
  Future<ScreenUsageDaily?> getByDate(String date) async {
    final db = await _db;
    final rows = await db.query(
      table,
      where: 'date = ?',
      whereArgs: [date],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ScreenUsageDaily.fromMap(Map<String, dynamic>.from(rows.first));
  }

  /// 读取 [startDate, endDate] 闭区间内的快照，按日期升序
  Future<List<ScreenUsageDaily>> getRange(
    String startDate,
    String endDate,
  ) async {
    final db = await _db;
    final rows = await db.query(
      table,
      where: 'date >= ? AND date <= ?',
      whereArgs: [startDate, endDate],
      orderBy: 'date ASC',
    );
    return rows
        .map((r) => ScreenUsageDaily.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// 最早已采集日期，空表返回 null；UI 用它区分「没用手机」与「还没开始记录」
  Future<DateTime?> earliestDate() async {
    final db = await _db;
    final rows = await db.rawQuery('SELECT MIN(date) AS d FROM $table');
    if (rows.isEmpty) {
      return null;
    }
    final raw = rows.first['d'] as String?;
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return ScreenUsageDaily.parseDateKey(raw);
  }
}
