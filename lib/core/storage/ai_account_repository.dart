import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 订阅账号登录态仓库（表 `ai_accounts`）
///
/// 刻意**不写** `sync_log`、也不进备份导出清单：refresh token 是长期凭据，
/// 跟着 WebDAV 同步到别的设备或备份文件里，泄露面比 API Key 更大。
/// 换设备/恢复备份后重新登录一次即可。
///
/// 一个厂商条目下可以有多行（多账号），选号与亲和由 `RaccoonAccountRouter`
/// 负责，本类只做存取。
class AiAccountRepository {
  static final AiAccountRepository instance = AiAccountRepository._();
  AiAccountRepository._();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  static const String tableName = 'ai_accounts';

  Future<List<AiAccount>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query(tableName, orderBy: 'sort_order ASC, created_at ASC');
    return maps.map((m) => AiAccount.fromMap(m)).toList();
  }

  /// 某厂商条目下的全部账号（按轮换顺序）
  Future<List<AiAccount>> getByProvider(String providerId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      tableName,
      where: 'provider_id = ?',
      whereArgs: [providerId],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return maps.map((m) => AiAccount.fromMap(m)).toList();
  }

  Future<AiAccount?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isEmpty) return null;
    return AiAccount.fromMap(maps.first);
  }

  /// 某厂商下排在最前的账号（老库迁移与单账号场景的兜底）
  Future<AiAccount?> getFirstForProvider(String providerId) async {
    final accounts = await getByProvider(providerId);
    return accounts.isEmpty ? null : accounts.first;
  }

  Future<void> upsert(AiAccount account) async {
    final db = await _dbHelper.database;
    final saved = account.copyWith(updatedAt: DateTime.now());
    await db.insert(tableName, saved.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 批量写入（账号顺序调整：一次性重排 sort_order，避免中途落库失败留下重复序号）
  Future<void> upsertAll(List<AiAccount> accounts) async {
    if (accounts.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final account in accounts) {
      batch.insert(
        tableName,
        account.copyWith(updatedAt: DateTime.now()).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除某厂商条目下的全部账号（厂商被删 / 切换回 API Key 模式）
  Future<void> deleteByProvider(String providerId) async {
    final db = await _dbHelper.database;
    await db.delete(tableName, where: 'provider_id = ?', whereArgs: [providerId]);
  }

  /// 数据管理页「清空全部数据」时一并清掉，避免残留登录态
  Future<void> clearAll() async {
    final db = await _dbHelper.database;
    await db.delete(tableName);
  }
}
