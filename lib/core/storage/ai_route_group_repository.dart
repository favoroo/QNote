import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';

/// 模型路由组仓库（表 `ai_route_groups`）
///
/// 与 [AiProviderRepository] 同一套约定：写操作都写 `sync_log`，WebDAV 增量同步
/// 按整行 `toMap()` 传递，因此组的成员配置与策略会自动跟随同步。
class AiRouteGroupRepository {
  static final AiRouteGroupRepository instance = AiRouteGroupRepository._();
  AiRouteGroupRepository._();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  static const String tableName = 'ai_route_groups';

  Future<List<AiRouteGroup>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(tableName, orderBy: 'created_at ASC');
    return maps.map((m) => AiRouteGroup.fromMap(m)).toList();
  }

  Future<AiRouteGroup?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AiRouteGroup.fromMap(maps.first);
  }

  /// 写入或更新一个路由组（按 id 判定），返回落库后的对象
  Future<AiRouteGroup> upsert(AiRouteGroup group) async {
    final db = await _dbHelper.database;
    final existing = await getById(group.id);
    final saved = group.copyWith(updatedAt: DateTime.now());
    if (existing == null) {
      await db.insert(tableName, saved.toMap());
    } else {
      await db.update(
        tableName,
        saved.toMap(),
        where: 'id = ?',
        whereArgs: [saved.id],
      );
    }
    await _syncLog.logChange(
      tableName: tableName,
      recordId: saved.id,
      operation: existing == null ? 'insert' : 'update',
      data: saved.toMap(),
    );
    return saved;
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: tableName,
      recordId: id,
      operation: 'delete',
    );
  }

  /// 迁移/导入写库（不写 sync_log，避免把本机迁移动作当成用户变更广播出去）
  Future<void> insertSilently(AiRouteGroup group) async {
    final db = await _dbHelper.database;
    await db.insert(
      tableName,
      group.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
