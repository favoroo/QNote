import 'package:sqflite/sqflite.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/weight_record.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/config/defaults.dart';

class ConfigRepository {
  static final ConfigRepository instance = ConfigRepository._internal();
  factory ConfigRepository() => instance;
  ConfigRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  Future<String?> getAppConfig(String key) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'app_configs',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (maps.isEmpty) return null;
    return maps.first['value'] as String;
  }

  Future<void> setAppConfig(String key, String value) async {
    final db = await _dbHelper.database;
    await db.insert('app_configs', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _syncLog.logChange(
      tableName: 'app_configs',
      recordId: key,
      operation: 'upsert',
      data: {'key': key, 'value': value},
    );
  }

  Future<void> deleteAppConfig(String key) async {
    final db = await _dbHelper.database;
    await db.delete('app_configs', where: 'key = ?', whereArgs: [key]);
    await _syncLog.logChange(
      tableName: 'app_configs',
      recordId: key,
      operation: 'delete',
    );
  }

  Future<List<AiConfig>> getAllAiConfigs() async {
    final db = await _dbHelper.database;
    final maps = await db.query('ai_configs', orderBy: 'created_at ASC');
    return maps.map((m) => AiConfig.fromMap(m)).toList();
  }

  Future<AiConfig?> getDefaultAiConfig() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'ai_configs',
      where: 'is_default = 1',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return AiConfig.fromMap(maps.first);
  }

  Future<AiConfig> insertAiConfig(AiConfig config) async {
    final db = await _dbHelper.database;
    await db.insert('ai_configs', config.toMap());
    await _syncLog.logChange(
      tableName: 'ai_configs',
      recordId: config.id,
      operation: 'insert',
      data: config.toMap(),
    );
    return config;
  }

  Future<AiConfig> updateAiConfig(AiConfig config) async {
    final db = await _dbHelper.database;
    final updated = config.copyWith(updatedAt: DateTime.now());
    await db.update(
      'ai_configs',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [config.id],
    );
    await _syncLog.logChange(
      tableName: 'ai_configs',
      recordId: config.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> deleteAiConfig(String id) async {
    final db = await _dbHelper.database;
    await db.delete('ai_configs', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'ai_configs',
      recordId: id,
      operation: 'delete',
    );
  }

  Future<List<ShortcutConfig>> getAllShortcutConfigs() async {
    final db = await _dbHelper.database;
    final maps = await db.query('shortcut_configs', orderBy: 'sort_order ASC');
    return maps.map((m) => ShortcutConfig.fromMap(m)).toList();
  }

  Future<List<ShortcutConfig>> getShortcutConfigs() => getAllShortcutConfigs();

  Future<ShortcutConfig> insertShortcutConfig(ShortcutConfig config) async {
    final db = await _dbHelper.database;
    await db.insert('shortcut_configs', config.toMap());
    await _syncLog.logChange(
      tableName: 'shortcut_configs',
      recordId: config.id,
      operation: 'insert',
      data: config.toMap(),
    );
    return config;
  }

  Future<ShortcutConfig> updateShortcutConfig(ShortcutConfig config) async {
    final db = await _dbHelper.database;
    final updated = config.copyWith(updatedAt: DateTime.now());
    await db.update(
      'shortcut_configs',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [config.id],
    );
    await _syncLog.logChange(
      tableName: 'shortcut_configs',
      recordId: config.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> deleteShortcutConfig(String id) async {
    final db = await _dbHelper.database;
    await db.delete('shortcut_configs', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'shortcut_configs',
      recordId: id,
      operation: 'delete',
    );
  }

  Future<UserProfile?> getUserProfile() async {
    final db = await _dbHelper.database;
    final maps = await db.query('user_profiles', limit: 1);
    if (maps.isEmpty) return null;
    return UserProfile.fromMap(maps.first);
  }

  Future<UserProfile> upsertUserProfile(UserProfile profile) async {
    final db = await _dbHelper.database;
    final updated = profile.copyWith(updatedAt: DateTime.now());
    await db.insert(
      'user_profiles',
      updated.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _syncLog.logChange(
      tableName: 'user_profile',
      recordId: updated.id,
      operation: 'upsert',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<UserProfile> saveUserProfile(UserProfile profile) =>
      upsertUserProfile(profile);

  Future<WebdavConfig?> getWebdavConfig() async {
    final db = await _dbHelper.database;
    final maps = await db.query('webdav_configs', limit: 1);
    if (maps.isEmpty) return null;
    return WebdavConfig.fromMap(maps.first);
  }

  Future<WebdavConfig> upsertWebdavConfig(WebdavConfig config) async {
    final db = await _dbHelper.database;
    final updated = config.copyWith(updatedAt: DateTime.now());
    await db.insert(
      'webdav_configs',
      updated.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return updated;
  }

  Future<void> deleteWebdavConfig(String id) async {
    final db = await _dbHelper.database;
    await db.delete('webdav_configs', where: 'id = ?', whereArgs: [id]);
  }



  Future<List<ChatSession>> getAllChatSessions({
    bool includeDeleted = false,
  }) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'chat_sessions',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'updated_at DESC',
    );
    return maps.map((m) => ChatSession.fromMap(m)).toList();
  }

  Future<ChatSession?> getChatSession(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return ChatSession.fromMap(maps.first);
  }

  Future<ChatSession> insertChatSession(ChatSession session) async {
    final db = await _dbHelper.database;
    await db.insert('chat_sessions', session.toMap());
    await _syncLog.logChange(
      tableName: 'chat_sessions',
      recordId: session.id,
      operation: 'insert',
      data: session.toMap(),
    );
    return session;
  }

  Future<ChatSession> updateChatSession(ChatSession session) async {
    final db = await _dbHelper.database;
    final updated = session.copyWith(updatedAt: DateTime.now());
    await db.update(
      'chat_sessions',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
    await _syncLog.logChange(
      tableName: 'chat_sessions',
      recordId: session.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> softDeleteChatSession(String id) async {
    final db = await _dbHelper.database;
    final existing = await getChatSession(id);
    if (existing == null) return;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'chat_sessions',
      {'is_deleted': 1, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      isDeleted: true,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'chat_sessions',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  Future<AiRoles?> getAiRoles() async {
    final value = await getAppConfig('ai_roles');
    if (value == null) return null;
    return AiRoles.fromJson(value);
  }

  Future<void> saveAiRoles(AiRoles roles) async {
    await setAppConfig('ai_roles', roles.toJson());
  }

  Future<AiTemperatures?> getAiTemperatures() async {
    final value = await getAppConfig('ai_temperatures');
    if (value == null) return null;
    return AiTemperatures.fromJson(value);
  }

  Future<void> saveAiTemperatures(AiTemperatures temps) async {
    await setAppConfig('ai_temperatures', temps.toJson());
  }

  Future<List<WeightRecord>> getWeightHistory() async {
    final profile = await getUserProfile();
    if (profile == null) return [];
    return profile.weightHistory;
  }

  Future<void> saveWeightHistory(List<WeightRecord> records) async {
    final profile = await getUserProfile();
    if (profile == null) return;
    final updated = profile.copyWith(
      weightHistory: records,
      updatedAt: DateTime.now(),
    );
    await upsertUserProfile(updated);
  }

  Future<void> ensureDefaultShortcuts() async {
    final existing = await getAllShortcutConfigs();
    if (existing.isNotEmpty) return;
    for (final config in defaultShortcutConfigs) {
      await insertShortcutConfig(config);
    }
  }

  Future<void> restoreDefaultShortcutConfigs() async {
    final db = await _dbHelper.database;
    await db.delete('shortcut_configs');
    for (final config in defaultShortcutConfigs) {
      await insertShortcutConfig(config);
    }
  }

  Future<void> ensureDefaultAiConfigs() async {
    final existing = await getAllAiConfigs();
    if (existing.isNotEmpty) return;
    for (final config in defaultAiConfigs) {
      await insertAiConfig(config);
    }
  }
}
