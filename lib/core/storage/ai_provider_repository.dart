import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

/// 厂商条目仓库（表 `ai_providers`）
///
/// 所有写操作都写 `sync_log`，WebDAV 增量同步按整行 `toMap()` 传递，
/// 因此密钥池与已启用模型列表会自动跟随同步，无需额外管道。
class AiProviderRepository {
  static final AiProviderRepository instance = AiProviderRepository._();
  AiProviderRepository._();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  static const String tableName = 'ai_providers';

  Future<List<AiProvider>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(tableName, orderBy: 'created_at ASC');
    return maps.map((m) => AiProvider.fromMap(m)).toList();
  }

  Future<AiProvider?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AiProvider.fromMap(maps.first);
  }

  Future<AiProvider?> getDefault() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      tableName,
      where: 'is_default = 1',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AiProvider.fromMap(maps.first);
  }

  /// 写入或更新一条厂商条目（按 id 判定），返回落库后的对象
  Future<AiProvider> upsert(AiProvider provider) async {
    final db = await _dbHelper.database;
    final existing = await getById(provider.id);
    final saved = provider.copyWith(updatedAt: DateTime.now());
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

  /// 物理清空本地表（不写 sync_log）
  ///
  /// 只给「一次性迁移在成功拷贝后清掉旧数据」这类场景用：写删除日志会把
  /// 对端设备的数据也一起删掉。
  Future<void> clearLocal() async {
    final db = await _dbHelper.database;
    await db.delete(tableName);
  }

  /// 迁移/导入写库（不写 sync_log，避免把本机迁移动作当成用户变更广播出去）
  Future<void> insertSilently(AiProvider provider) async {
    final db = await _dbHelper.database;
    await db.insert(tableName, provider.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 把默认标记收敛到唯一一条：设置 [id] 为默认，其余清除
  Future<void> setDefault(String id) async {
    final all = await getAll();
    for (final provider in all) {
      final shouldBeDefault = provider.id == id;
      if (provider.isDefault == shouldBeDefault) continue;
      await upsert(provider.copyWith(isDefault: shouldBeDefault));
    }
  }
}