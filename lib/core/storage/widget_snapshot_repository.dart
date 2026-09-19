import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/widget_snapshot.dart';

final widgetSnapshotRepositoryProvider = Provider<WidgetSnapshotRepository>(
  (ref) => WidgetSnapshotRepository(),
);

/// 桌面小组件快照仓储
///
/// **有意不写 sync_log**：快照是纯派生缓存，任何设备从原始表都能重算出来。
/// 若照常 logChange，会把无意义的写入混进 WebDAV 增量包（sync_log_repository
/// 的 buildDeltaJson），既膨胀流量又可能在另一端覆盖本地更新的值。这也是本项目
/// 对 screen_usage_daily、health_daily_metrics 采取的同一约定。
///
/// 方法命名与业务仓储略有出入：主键是 (key, date) 复合键而非独立 id，故只有
/// get/put 语义，没有 insert/update 之分，也不做软删除（缓存行直接覆盖）。
class WidgetSnapshotRepository {
  static const String table = 'widget_snapshot';

  static final WidgetSnapshotRepository _instance = WidgetSnapshotRepository._internal();
  factory WidgetSnapshotRepository() => _instance;
  WidgetSnapshotRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<Database> get _db async => await _dbHelper.database;

  /// 读取一行快照，[date] 默认空串对应与日期无关的高频小值
  Future<WidgetSnapshot?> get(String key, {String date = ''}) async {
    final db = await _db;
    final rows = await db.query(
      table,
      where: 'key = ? AND date = ?',
      whereArgs: [key, date],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return WidgetSnapshot.fromMap(rows.first);
  }

  /// 列出某天（含 date='' 的全局项）的全部快照，供原生侧一次性对账
  Future<List<WidgetSnapshot>> getAll({String? date}) async {
    final db = await _db;
    final rows = date == null
        ? await db.query(table, orderBy: 'key ASC, date ASC')
        : await db.query(
            table,
            where: 'date = ?',
            whereArgs: [date],
            orderBy: 'key ASC',
          );
    return rows.map(WidgetSnapshot.fromMap).toList();
  }

  /// 幂等写入：同 (key, date) 直接覆盖为最新值
  Future<void> put(WidgetSnapshot snapshot) async {
    final db = await _db;
    await db.insert(
      table,
      snapshot.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量写入共用一个事务，避免逐条开事务放大热路径开销
  Future<void> putAll(List<WidgetSnapshot> snapshots) async {
    if (snapshots.isEmpty) {
      return;
    }
    final db = await _db;
    await db.transaction((txn) async {
      for (final snapshot in snapshots) {
        await txn.insert(
          table,
          snapshot.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<int> hardDelete(String key, {String date = ''}) async {
    final db = await _db;
    return await db.delete(
      table,
      where: 'key = ? AND date = ?',
      whereArgs: [key, date],
    );
  }
}
