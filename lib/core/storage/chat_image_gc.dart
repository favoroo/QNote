import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/utils/chat_image_refs.dart';

/// 一次图片回收的结果计数。
class AiImageCleanupResult {
  final int deletedFiles;
  final int freedBytes;
  final int keptFiles;
  final List<String> failedPaths;

  const AiImageCleanupResult({
    this.deletedFiles = 0,
    this.freedBytes = 0,
    this.keptFiles = 0,
    this.failedPaths = const [],
  });

  static const AiImageCleanupResult none = AiImageCleanupResult();
}

/// `images/ai/` 的只读盘点结果。
class AiImageInventory {
  final int fileCount;
  final int totalBytes;
  final int orphanCount;
  final int orphanBytes;

  const AiImageInventory({
    this.fileCount = 0,
    this.totalBytes = 0,
    this.orphanCount = 0,
    this.orphanBytes = 0,
  });

  static const AiImageInventory empty = AiImageInventory();
}

/// 小Q 生成图片（`images/ai/`）的引用统计与磁盘回收。
///
/// 「谁还在引用这些文件」这件事被三个入口依赖：删除单条会话、批量回收、以及 WebDAV
/// 图片同步的本地孤儿清理。三处必须用同一套保护集，否则某个入口口径偏窄就会误删
/// 仍在显示的图，因此本类是**全仓唯一**的保护集实现。
///
/// 安全约定：
/// 1. 只操作 `images/ai/` 目录内**实际列出的文件**，从不按消息里的字符串拼路径，
///    这样消息内容里出现的 `../` 等文本永远影响不到文件系统；
/// 2. 只删「无任何引用」的文件，且用户相册附件、picker 临时文件天然不在该目录内，
///    不参与回收；
/// 3. 逐文件 try/catch，失败只记日志并计数，绝不向上抛 —— 数据库行此时已删除，
///    向上抛会让 UI 误报「删除失败」，残留文件交给「立即回收」二次清扫。
class ChatImageGc {
  static final ChatImageGc instance = ChatImageGc._internal();
  factory ChatImageGc() => instance;
  ChatImageGc._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// 生成图片子目录名，须与 `GenerateImageTool._subfolder` 保持一致
  static const String subfolder = 'ai';

  Directory? _aiDirOverride;

  /// 单测注入 `images/ai` 目录（生产保持 null，运行时按 documents 目录求值）。
  @visibleForTesting
  set aiImagesDirOverride(Directory? dir) => _aiDirOverride = dir;

  /// 生成图片目录；Web 端无本地文件系统，返回 null 表示所有文件操作短路。
  Future<Directory?> resolveAiImagesDir() async {
    if (kIsWeb) {
      return null;
    }
    final override = _aiDirOverride;
    if (override != null) {
      return override;
    }
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'images', subfolder));
  }

  /// 保护集：所有仍可能引用 `images/ai/` 文件的键（小写 basename）。
  ///
  /// 覆盖六处来源，宁可少删不可误删：
  /// - 其余会话：按 id 排除本次待删目标，且**故意不过滤 `is_deleted`** —— 墓碑行仍留在
  ///   库里，它引用的文件仍是有效证据；
  /// - 日记 `photos` / 笔记 `images` / 头像 `avatar_path`：用户常把生成图存进笔记日记，
  ///   引用的是同一个 `images/ai/` 路径；
  /// - `app_configs.value`：记忆与自定义技能是 markdown，正文里可能内联生成图路径，
  ///   一旦被删后续写回笔记就会指向空文件。
  Future<Set<String>> collectReferencedImageKeys({
    Set<String>? excludeSessionIds,
  }) async {
    final keys = <String>{};
    try {
      final db = await _dbHelper.database;

      final sessions = await db.query(
        'chat_sessions',
        columns: ['id', 'messages'],
      );
      for (final row in sessions) {
        final id = row['id']?.toString() ?? '';
        if (excludeSessionIds != null && excludeSessionIds.contains(id)) {
          continue;
        }
        keys.addAll(extractChatAiImageKeys(row['messages'] as String?));
      }

      final textRows = await db.query(
        'diary_records',
        columns: ['photos'],
      );
      for (final row in textRows) {
        keys.addAll(extractChatAiImageKeys(row['photos'] as String?));
      }

      final noteRows = await db.query('notes', columns: ['images']);
      for (final row in noteRows) {
        keys.addAll(extractChatAiImageKeys(row['images'] as String?));
      }

      final profiles = await db.query('user_profiles', columns: ['avatar_path']);
      for (final row in profiles) {
        keys.addAll(extractChatAiImageKeys(row['avatar_path'] as String?));
      }

      final configs = await db.query('app_configs', columns: ['value']);
      for (final row in configs) {
        keys.addAll(extractChatAiImageKeys(row['value'] as String?));
      }
    } catch (error) {
      // 读不到保护集时**不能**当作「无人引用」继续删，交由调用方拿到空集后自然放弃回收
      LoggerService.instance.logDatabase(
        '统计生成图片引用失败，本轮跳过图片回收',
        details: error.toString(),
        level: LogLevel.error,
      );
      return <String>{};
    }
    return keys;
  }

  /// 列出 `images/ai/` 下的实际文件，键为小写 basename。
  ///
  /// 目录取不到（path_provider 未就绪、无权限、纯单测环境）时返回空表：
  /// 占用估算与回收都属于「有文件就顺带处理」的附加能力，绝不能让文件层失败
  /// 把删除会话或统计整条链路带崩。
  Future<Map<String, File>> listAiImageFiles() async {
    Directory? dir;
    try {
      dir = await resolveAiImagesDir();
    } catch (error) {
      LoggerService.instance.logDatabase(
        '定位生成图片目录失败，本轮跳过图片处理',
        details: error.toString(),
        level: LogLevel.warning,
      );
      return const {};
    }
    if (dir == null || !await dir.exists()) {
      return const {};
    }
    final result = <String, File>{};
    try {
      // 生图按 uuid 命名、单层平铺，无需递归
      await for (final entity in dir.list()) {
        if (entity is File) {
          result[p.basename(entity.path).toLowerCase()] = entity;
        }
      }
    } catch (error) {
      LoggerService.instance.logDatabase(
        '扫描生成图片目录失败',
        details: '${dir.path}: $error',
        level: LogLevel.warning,
      );
    }
    return result;
  }

  /// 删除指定键集合中**已无任何引用**的生成图片。
  ///
  /// [keys] 通常是刚被删除的会话所引用的图片集；内部会在**删完数据库行之后**重新计算
  /// 保护集，因此同一批次里两个会话共用一张图时也能删净。
  Future<AiImageCleanupResult> deleteFilesForKeys(Set<String> keys) async {
    if (keys.isEmpty) {
      return AiImageCleanupResult.none;
    }
    final protected = await collectReferencedImageKeys();
    final victims = keys.difference(protected);
    return _deleteFromListing(victims);
  }

  /// 回收 `images/ai/` 里所有已无引用的孤儿图片（「立即回收」与同步孤儿清理共用）。
  Future<AiImageCleanupResult> deleteUnreferencedAiImages() async {
    final protected = await collectReferencedImageKeys();
    final listing = await listAiImageFiles();
    final victims = listing.keys.toSet().difference(protected);
    return _deleteFromListing(victims, listing: listing);
  }

  /// 只读盘点：目录总体积与其中可回收的孤儿部分。
  Future<AiImageInventory> inventoryAiImages() async {
    final protected = await collectReferencedImageKeys();
    final listing = await listAiImageFiles();
    var fileCount = 0;
    var totalBytes = 0;
    var orphanCount = 0;
    var orphanBytes = 0;
    for (final entry in listing.entries) {
      int size;
      try {
        size = await entry.value.length();
      } catch (error) {
        LoggerService.instance.logDatabase(
          '读取生成图片体积失败',
          details: '${entry.value.path}: $error',
          level: LogLevel.warning,
        );
        continue;
      }
      fileCount++;
      totalBytes += size;
      if (!protected.contains(entry.key)) {
        orphanCount++;
        orphanBytes += size;
      }
    }
    return AiImageInventory(
      fileCount: fileCount,
      totalBytes: totalBytes,
      orphanCount: orphanCount,
      orphanBytes: orphanBytes,
    );
  }

  /// 按实际目录列表删除文件：只有列出来的文件才可能被删，天然杜绝路径拼接越权。
  Future<AiImageCleanupResult> _deleteFromListing(
    Set<String> wantedKeys, {
    Map<String, File>? listing,
  }) async {
    if (kIsWeb || wantedKeys.isEmpty) {
      return AiImageCleanupResult.none;
    }
    final files = listing ?? await listAiImageFiles();
    var deleted = 0;
    var freed = 0;
    var kept = 0;
    final failed = <String>[];
    for (final entry in files.entries) {
      if (!wantedKeys.contains(entry.key)) {
        continue;
      }
      final file = entry.value;
      try {
        final size = await file.length();
        await file.delete();
        deleted++;
        freed += size;
      } catch (error) {
        kept++;
        failed.add(file.path);
        LoggerService.instance.logDatabase(
          '删除会话生成图片失败，留待「立即回收」二次清扫',
          details: '${file.path}: $error',
          level: LogLevel.warning,
        );
      }
    }
    return AiImageCleanupResult(
      deletedFiles: deleted,
      freedBytes: freed,
      keptFiles: kept,
      failedPaths: failed,
    );
  }
}
