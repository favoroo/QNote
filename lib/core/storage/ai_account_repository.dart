import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 订阅账号登录态仓库（表 `ai_accounts`）
///
/// 刻意**不写** `sync_log`、也不进备份导出清单：refresh token 是长期凭据，
/// 跟着 WebDAV 同步到别的设备或备份文件里，泄露面比 API Key 更大。
/// 换设备/恢复备份后重新登录一次即可。
class AiAccountRepository {
  static final AiAccountRepository instance = AiAccountRepository._();
  AiAccountRepository._();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  static const String tableName = 'ai_accounts';

  Future<List<AiAccount>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(tableName, orderBy: 'updated_at ASC');
    return maps.map((m) => AiAccount.fromMap(m)).toList();
  }

  Future<AiAccount?> getByProvider(String providerId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      tableName,
      where: 'provider_id = ?',
      whereArgs: [providerId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AiAccount.fromMap(maps.first);
  }

  Future<void> upsert(AiAccount account) async {
    final db = await _dbHelper.database;
    final saved = account.copyWith(updatedAt: DateTime.now());
    await db.insert(
      tableName,
      saved.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String providerId) async {
    final db = await _dbHelper.database;
    await db.delete(
      tableName,
      where: 'provider_id = ?',
      whereArgs: [providerId],
    );
  }

  /// 数据管理页「清空全部数据」时一并清掉，避免残留登录态
  Future<void> clearAll() async {
    final db = await _dbHelper.database;
    await db.delete(tableName);
  }
}
