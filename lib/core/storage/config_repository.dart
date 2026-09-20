import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/chat_image_gc.dart';
import 'package:qnote_flutter/core/storage/chat_storage_usage.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/core/utils/chat_image_refs.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/agent_memory.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
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

  /// 按前缀批量读取 app_configs 键值（用于小Q用户技能等动态数量的配置）
  Future<Map<String, String>> getAppConfigsByPrefix(String prefix) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'app_configs',
      where: 'key LIKE ?',
      whereArgs: ['$prefix%'],
    );
    return {
      for (final m in maps) m['key'] as String: m['value'] as String,
    };
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

  /// 只切换置顶标志，**不改 `updated_at`**。
  ///
  /// 不能复用 [updateChatSession]：它会无条件把 `updatedAt` 刷成 now，而历史抽屉的
  /// 「7 天内 / 30 天内 / 某年某月」分组完全按 `updatedAt` 归档 —— 置顶一个三个月前
  /// 的对话会把它整体搬进「7 天内」，一个纯展示动作篡改了数据的时间归属。
  /// （`note_repository.togglePin` 就同时写了 `updated_at`，那是 notes 的既存问题，
  /// 这里刻意不照抄。）
  ///
  /// 同步日志仍带整行 `toMap()`（含原 `updatedAt`）：`SyncLogRepository` 的 delta
  /// 打包按整行 upsert 外发，见 [hardDeleteChatSessions] 上方硬约束。
  Future<void> setChatSessionPinned(String id, bool isPinned) async {
    final db = await _dbHelper.database;
    final existing = await getChatSession(id);
    if (existing == null) {
      return;
    }
    await db.update(
      'chat_sessions',
      {'is_pinned': isPinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _syncLog.logChange(
      tableName: 'chat_sessions',
      recordId: id,
      operation: 'update',
      data: existing.copyWith(isPinned: isPinned).toMap(),
    );
  }

  /// 软删除会话（只打标记，不释放空间）。
  ///
  /// 保留仅为兼容旧客户端写入的墓碑与灰度回退，新代码一律改用 [hardDeleteChatSessions]：
  /// 软删的行仍完整留在 `chat_sessions.messages` 里（SQLite 文件不会变小），且它会把
  /// 整行内容当 `update` 写进 sync_log，导致已删会话在其它设备被全量快照回灌复活。
  @Deprecated('软删除不释放空间且会造成多端复活，请改用 hardDeleteChatSessions')
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

  /// 物理删除会话：真正释放这条对话占用的消息记录与独占生成图片。
  ///
  /// 删除范围严格限定在「这条对话自身」：消息（含内联图片 JSON 与 undo 快照）随行消失，
  /// 外加它独占的 `images/ai/` 生成图；**绝不级联**日记/笔记/待办等业务数据，也不动虚拟
  /// 工作区（VFS 全是表映射，本就不落盘）。
  ///
  /// 三条硬约束，改动时请勿破坏：
  /// 1. 必须写 `operation: 'delete'` 的最小墓碑（`data: null`）。`SyncLogRepository` 打包
  ///    delta 时把非 delete 的 operation 一律归入 upserts 并连整行 data 外发，写成
  ///    'update' 会让已删会话在多端复活，且每次删除都往 sync_log 塞一份完整会话 JSON；
  /// 2. 幂等：行不存在也不报错，但**仍写墓碑**，保证「A 端删除 → B 端已本地删过 →
  ///    仍需转发给 C 端」的链路不断（旧实现 `if (existing == null) return;` 正是断点）；
  /// 3. 事务回调内只用 `txn`：复用 `_syncLog.logChange` 会走 `Database` 对象，其写操作
  ///    排在事务之后，既有死锁风险又会让墓碑漏在事务外。
  Future<ChatSessionDeleteReport> hardDeleteChatSessions(
    List<String> ids,
  ) async {
    final targets = ids.where((id) => id.trim().isNotEmpty).toSet();
    if (targets.isEmpty) {
      return ChatSessionDeleteReport.empty;
    }

    final db = await _dbHelper.database;
    final idList = targets.toList();
    final placeholders = List.filled(idList.length, '?').join(', ');

    // 事务前只读：先量出这条对话占多大，删掉之后就没有原始行可查了
    final rows = await db.query(
      'chat_sessions',
      columns: [
        'id',
        'messages',
        'LENGTH(CAST(messages AS BLOB)) AS msg_bytes',
      ],
      where: 'id IN ($placeholders)',
      whereArgs: idList,
    );

    var messageCount = 0;
    var imageRefCount = 0;
    var messageBytes = 0;
    final ownedImageKeys = <String>{};
    for (final row in rows) {
      final raw = row['messages'] as String?;
      ownedImageKeys.addAll(extractChatAiImageKeys(raw));
      final summary = summarizeMessageRefs(raw);
      messageCount += summary.messageCount;
      imageRefCount += summary.imageRefCount;
      messageBytes += (row['msg_bytes'] as int?) ?? 0;
    }

    await db.transaction((txn) async {
      final batch = txn.batch();
      final nowStr = DateTime.now().toIso8601String();
      for (final id in idList) {
        batch.delete('chat_sessions', where: 'id = ?', whereArgs: [id]);
        batch.insert('sync_log', {
          'table_name': 'chat_sessions',
          'record_id': id,
          'operation': 'delete',
          'data': null,
          'timestamp': nowStr,
        });
      }
      await batch.commit(noResult: true);
    });

    // 文件回收必须在事务提交之后：顺序反过来时一旦事务回滚，就会出现
    // 「图片已丢失、消息还在」的不可接受损坏。
    // deleteFilesForKeys 会在行已消失的前提下重算保护集，故同批两个会话共用一张图也能删净。
    final cleanup = ownedImageKeys.isEmpty
        ? AiImageCleanupResult.none
        : await ChatImageGc.instance.deleteFilesForKeys(ownedImageKeys);

    return ChatSessionDeleteReport(
      deletedSessions: rows.length,
      messageCount: messageCount,
      imageRefCount: imageRefCount,
      deletedImageFiles: cleanup.deletedFiles,
      imageFreedBytes: cleanup.freedBytes,
      keptImageFiles: cleanup.keptFiles,
      freedBytes: messageBytes + cleanup.freedBytes,
      failedPaths: cleanup.failedPaths,
    );
  }

  /// 删除单个会话（语义同 [hardDeleteChatSessions]）。
  Future<ChatSessionDeleteReport> hardDeleteChatSession(String id) {
    return hardDeleteChatSessions([id]);
  }

  /// 回收旧版本软删除留下的墓碑行（数据其实还躺在库里，是历史欠账）。
  Future<ChatSessionDeleteReport> purgeTombstonedChatSessions() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'chat_sessions',
      columns: ['id'],
      where: 'is_deleted = 1',
    );
    final ids = rows.map((row) => row['id']?.toString() ?? '').toList();
    return hardDeleteChatSessions(ids);
  }

  /// 只读估算对话历史占用：活跃会话、待回收墓碑、生成图片与数据库文件体积。
  Future<ChatStorageUsage> estimateChatStorageUsage() async {
    var activeSessions = 0;
    var activeBytes = 0;
    var tombstones = 0;
    var tombstoneBytes = 0;
    int? databaseBytes;
    try {
      final db = await _dbHelper.database;
      final active = await _sumMessagesStorage(db, where: 'is_deleted = 0');
      final tomb = await _sumMessagesStorage(db, where: 'is_deleted = 1');
      activeSessions = active.$1;
      activeBytes = active.$2;
      tombstones = tomb.$1;
      tombstoneBytes = tomb.$2;
      databaseBytes = await _estimateDatabaseBytes(db);
    } catch (error) {
      LoggerService.instance.logDatabase(
        '统计对话存储占用失败',
        details: error.toString(),
        level: LogLevel.warning,
      );
    }
    final inventory = await ChatImageGc.instance.inventoryAiImages();
    return ChatStorageUsage(
      activeSessions: activeSessions,
      activeMessagesBytes: activeBytes,
      tombstonedSessions: tombstones,
      tombstonedBytes: tombstoneBytes,
      aiImageFiles: inventory.fileCount,
      aiImageBytes: inventory.totalBytes,
      orphanImageFiles: inventory.orphanCount,
      orphanImageBytes: inventory.orphanBytes,
      databaseFileBytes: databaseBytes,
    );
  }

  /// 整理数据库（VACUUM）：把已删行占用的页真正还给文件系统。
  ///
  /// 建表期未开 `PRAGMA auto_vacuum`，`incremental_vacuum` 不可用，VACUUM 是唯一收缩路径
  /// —— 这正是「删了行文件也不变小」的根因，故界面文案表达为「整理」而非「删除」。
  /// 代价是需要约 2× 库文件大小的临时磁盘并独占重写整个 db，只在用户显式点击时执行，
  /// 且**必须在事务外**；Web 端存储实为 IndexedDB，直接返回 false。
  Future<bool> vacuumDatabase() async {
    if (kIsWeb) {
      return false;
    }
    try {
      final db = await _dbHelper.database;
      await db.execute('VACUUM');
      LoggerService.instance.logDatabase('已整理数据库（VACUUM）');
      return true;
    } catch (error) {
      LoggerService.instance.logDatabase(
        '整理数据库失败（当前平台可能不支持 VACUUM）',
        details: error.toString(),
        level: LogLevel.warning,
      );
      return false;
    }
  }

  /// 按条件汇总会话消息体积；返回（行数, 字节数）。
  ///
  /// 必须 `CAST(messages AS BLOB)` 再取 `LENGTH`：`LENGTH(text)` 返回**字符数**，
  /// 中文内容会低估 2~3 倍。
  Future<(int, int)> _sumMessagesStorage(
    DatabaseExecutor db, {
    required String where,
  }) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c, '
      'IFNULL(SUM(LENGTH(CAST(messages AS BLOB))), 0) AS b '
      'FROM chat_sessions WHERE $where',
    );
    if (rows.isEmpty) {
      return (0, 0);
    }
    return (
      (rows.first['c'] as int?) ?? 0,
      (rows.first['b'] as int?) ?? 0,
    );
  }

  /// 数据库文件体积（page_size × page_count）；个别平台（如 Web WASM）不支持该 PRAGMA，
  /// 读不到时返回 null，由界面降级为只显示消息与图片体积。
  Future<int?> _estimateDatabaseBytes(DatabaseExecutor db) async {
    try {
      final sizeRows = await db.rawQuery('PRAGMA page_size');
      final countRows = await db.rawQuery('PRAGMA page_count');
      final pageSize = (sizeRows.first['page_size'] as int?) ?? 0;
      final pageCount = (countRows.first['page_count'] as int?) ?? 0;
      if (pageSize <= 0 || pageCount <= 0) {
        return null;
      }
      return pageSize * pageCount;
    } catch (_) {
      return null;
    }
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

  /// 读取小Q长期记忆文档（app_configs 键 `agent_memory_` + 分类名）；不存在返回空文档
  Future<AgentMemoryDocument> getAgentMemory(String category) async {
    final value = await getAppConfig('agent_memory_$category');
    if (value == null || value.isEmpty) {
      return AgentMemoryDocument(category: category);
    }
    try {
      return AgentMemoryDocument.fromJson(value);
    } catch (_) {
      // 历史数据损坏时按空文档兜底，避免阻断对话上下文组装
      return AgentMemoryDocument(category: category);
    }
  }

  /// 保存小Q长期记忆文档（经 setAppConfig 自动写入同步日志，参与 WebDAV 云同步）
  Future<void> saveAgentMemory(AgentMemoryDocument doc) async {
    await setAppConfig('agent_memory_${doc.category}', doc.toJson());
  }

  /// 读取全部分类的小Q长期记忆文档（顺序固定为 user → agent）
  Future<List<AgentMemoryDocument>> getAllAgentMemories() async {
    final result = <AgentMemoryDocument>[];
    for (final category in AgentMemoryCategory.all) {
      result.add(await getAgentMemory(category));
    }
    return result;
  }

  /// 读取全部小Q用户技能（app_configs 键前缀 `agent_skill_`）；损坏数据跳过
  Future<List<AgentSkill>> getUserSkills() async {
    final entries = await getAppConfigsByPrefix(
      ConfigRepository.userSkillKeyPrefix,
    );
    final skills = <AgentSkill>[];
    for (final entry in entries.entries) {
      try {
        skills.add(AgentSkill.fromJson(entry.value));
      } catch (_) {
        // 单条数据损坏时跳过，不影响其余技能加载
      }
    }
    skills.sort((a, b) => a.name.compareTo(b.name));
    return skills;
  }

  /// 保存一个小Q用户技能（经 setAppConfig 自动写入同步日志，参与 WebDAV 云同步）
  Future<void> saveUserSkill(AgentSkill skill) async {
    await setAppConfig(
      '${ConfigRepository.userSkillKeyPrefix}${skill.name}',
      skill.toJson(),
    );
  }

  /// 删除一个小Q用户技能
  Future<void> deleteUserSkill(String name) async {
    await deleteAppConfig('${ConfigRepository.userSkillKeyPrefix}$name');
  }

  /// 小Q用户技能在 app_configs 中的键前缀
  static const String userSkillKeyPrefix = 'agent_skill_';

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
    if (existing.isEmpty) {
      for (final config in defaultShortcutConfigs) {
        await insertShortcutConfig(config);
      }
      return;
    }

    // 老用户数据平滑升级：饮食移除种类(type)字段，评价(rating)升级为四档
    for (final config in existing) {
      if (config.id == 'diet') {
        final hasOldType = config.fields.any((f) => f.id == 'type');
        final ratingField = config.fields.where((f) => f.id == 'rating').firstOrNull;
        final needsRatingUpgrade = ratingField == null || !ratingField.options.contains('过于放纵');
        if (hasOldType || needsRatingUpgrade) {
          final defaultDiet = defaultShortcutConfigs.firstWhere((c) => c.id == 'diet');
          final updated = config.copyWith(
            fields: defaultDiet.fields,
            updatedAt: DateTime.now(),
          );
          await updateShortcutConfig(updated);
        }
        break;
      }
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
    // 默认配置已移除，直接返回
  }
}
