import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:qnote_flutter/core/storage/database_helper.dart';

/// P1-13: 把 JSON 序列化 + UTF8 编码移到 isolate 的顶层函数。
///
/// 必须是顶层函数（不能是闭包或实例方法），否则 isolate 无法访问。
/// 适用于大快照（MB 级）的序列化，避免主线程卡顿。
Uint8List _encodeJsonToBytes(Map<String, dynamic> data) {
  return Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
  );
}

class SyncResult {
  final bool success;
  final bool wasFullSync;
  final int changeCount;
  final String? error;
  final int? uploadSizeBytes;

  SyncResult({
    required this.success,
    this.wasFullSync = false,
    this.changeCount = 0,
    this.error,
    this.uploadSizeBytes,
  });
}

class WebdavService {
  static final WebdavService _instance = WebdavService._();
  static WebdavService get instance => _instance;
  WebdavService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
    ),
  );
  WebdavConfig? _config;

  static const String _manifestFile = 'qnote_manifest.json';
  static const String _snapshotFile = 'qnote_snapshot.json';
  static const String _deltaFile = 'qnote_delta.json';
  static const int _maxDeltaCount = 10;

  WebdavConfig? get config => _config;

  void updateConfig(WebdavConfig config) {
    var serverUrl = config.serverUrl.trim();
    if (!serverUrl.endsWith('/')) {
      serverUrl = '$serverUrl/';
    }

    var remotePath = config.remotePath.trim();
    while (remotePath.startsWith('/')) {
      remotePath = remotePath.substring(1);
    }
    if (remotePath.isNotEmpty && !remotePath.endsWith('/')) {
      remotePath = '$remotePath/';
    }

    _config = config.copyWith(
      serverUrl: serverUrl,
      remotePath: remotePath,
    );

    _dio.options.baseUrl = serverUrl;
    _dio.options.headers['Authorization'] =
        'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}';

    LoggerService.instance.logNetwork(
      '更新WebDAV配置',
      details: '服务器=$serverUrl, 路径=$remotePath',
    );
  }

  Future<bool> testConnection() async {
    if (_config == null) return false;

    LoggerService.instance.logNetwork('测试WebDAV连接...');

    try {
      final response = await _dio.request(
        _config!.remotePath,
        options: Options(method: 'PROPFIND', headers: {'Depth': '0'}),
      );

      final success = response.statusCode == 207;
      LoggerService.instance.logNetwork(
        success ? 'WebDAV连接测试成功' : 'WebDAV连接测试失败',
        details: '状态码=${response.statusCode}',
        level: success ? LogLevel.info : LogLevel.warning,
      );

      return success;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        'WebDAV连接测试异常: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  Future<bool> uploadFile(String localPath, String remoteName) async {
    if (_config == null) return false;

    try {
      final file = File(localPath);
      if (!await file.exists()) {
        LoggerService.instance.logNetwork(
          '上传失败: 本地文件不存在',
          level: LogLevel.warning,
          details: localPath,
        );
        return false;
      }

      final bytes = await file.readAsBytes();
      final remotePath = '${_config!.remotePath}$remoteName';

      LoggerService.instance.logNetwork(
        '开始上传文件',
        details: '$localPath -> $remoteName, 大小≈${(bytes.length / 1024).toStringAsFixed(1)}KB',
      );

      await _dio.put(remotePath, data: Stream.fromIterable([bytes]));

      LoggerService.instance.logNetwork('文件上传成功', details: remoteName);
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '文件上传失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  Future<bool> downloadFile(String remoteName, String localPath) async {
    if (_config == null) return false;

    try {
      final remotePath = '${_config!.remotePath}$remoteName';

      LoggerService.instance.logNetwork(
        '开始下载文件',
        details: '$remoteName -> $localPath',
      );

      final response = await _dio.get<List<int>>(
        remotePath,
        options: Options(responseType: ResponseType.bytes),
      );
      final file = File(localPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(response.data!);

      LoggerService.instance.logNetwork(
        '文件下载成功',
        details: '$remoteName, 大小≈${(response.data!.length / 1024).toStringAsFixed(1)}KB',
      );
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '文件下载失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  Future<List<String>> listFiles() async {
    if (_config == null) return [];
    try {
      final response = await _dio.request(
        _config!.remotePath,
        data:
            '<?xml version="1.0" encoding="utf-8"?>'
            '<propfind xmlns="DAV:">'
            '<prop><resourcetype/></prop>'
            '</propfind>',
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '1', 'Content-Type': 'application/xml'},
        ),
      );
      if (response.statusCode != 207) return [];
      final body = response.data as String;
      final hrefRegex = RegExp(r'<href>([^<]+)</href>');
      final matches = hrefRegex.allMatches(body);
      final files = matches
          .map((m) => m.group(1)!)
          .where((h) => h != _config!.remotePath)
          .toList();

      LoggerService.instance.logNetwork(
        '列出远程文件完成',
        details: '找到 ${files.length} 个文件',
      );

      return files;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '列出远程文件失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return [];
    }
  }

  Future<bool> deleteFile(String remoteName) async {
    if (_config == null) return false;
    try {
      final remotePath = '${_config!.remotePath}$remoteName';

      LoggerService.instance.logNetwork('删除远程文件', details: remoteName);

      await _dio.delete(remotePath);

      LoggerService.instance.logNetwork('远程文件删除成功', details: remoteName);
      return true;
    } catch (e, stackTrace) {
      if (e is DioException && e.response?.statusCode == 404) {
        LoggerService.instance.logNetwork('远程文件不存在(404)', details: remoteName);
        return true;
      }
      LoggerService.instance.logNetwork(
        '删除远程文件失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  Future<bool> createRemoteDirectory() async {
    if (_config == null) return false;
    try {
      LoggerService.instance.logNetwork('创建远程目录', details: _config!.remotePath);

      await _dio.request(
        _config!.remotePath,
        options: Options(method: 'MKCOL'),
      );

      LoggerService.instance.logNetwork('远程目录创建成功');
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '创建远程目录失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  Future<List<String>> propFind(String path) async {
    if (_config == null) return [];
    try {
      final response = await _dio.request(
        path,
        data:
            '<?xml version="1.0" encoding="utf-8"?>'
            '<propfind xmlns="DAV:">'
            '<prop><resourcetype/><getlastmodified/></prop>'
            '</propfind>',
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '1', 'Content-Type': 'application/xml'},
        ),
      );
      if (response.statusCode != 207) return [];
      final body = response.data as String;
      final hrefRegex = RegExp(
        r'<D:href[^>]*>([^<]+)</D:href>',
        caseSensitive: false,
      );
      var matches = hrefRegex.allMatches(body);
      if (matches.isEmpty) {
        final plainHrefRegex = RegExp(
          r'<href[^>]*>([^<]+)</href>',
          caseSensitive: false,
        );
        matches = plainHrefRegex.allMatches(body);
      }
      return matches.map((m) => m.group(1)!).where((h) {
        final decoded = Uri.decodeFull(h);
        return decoded != path && decoded != '$path/';
      }).toList();
    } catch (e) {
      return [];
    }
  }

  /// 上传 JSON 数据。返回成功上传的字节数；失败返回 -1。
  ///
  /// P1-13: 新增 `useIsolate` 参数，对大快照（MB 级）走 compute 在 isolate 中
  /// 完成 JSON 序列化 + UTF8 编码，避免阻塞 UI 线程。manifest/delta 通常很小，
  /// 默认走主线程避免 isolate 启动开销（~150ms）。
  Future<int> _uploadJsonData(
    Map<String, dynamic> data,
    String filename, {
    bool useIsolate = false,
  }) async {
    if (_config == null) return -1;
    try {
      // P1-13: 大快照走 isolate 编码，小数据走主线程
      final Uint8List bytes;
      if (useIsolate) {
        bytes = await compute(_encodeJsonToBytes, data);
      } else {
        bytes = _encodeJsonToBytes(data);
      }
      final remotePath = '${_config!.remotePath}$filename';

      LoggerService.instance.logSync(
        '上传JSON数据',
        details: '文件=$filename, 大小≈${(bytes.length / 1024).toStringAsFixed(1)}KB'
            '${useIsolate ? ' (isolate)' : ''}',
      );

      await _dio.put(
        remotePath,
        data: Stream.fromIterable([bytes]),
        options: Options(contentType: 'application/json'),
      );

      LoggerService.instance.logSync('JSON数据上传成功', details: filename);
      return bytes.length;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        'JSON数据上传失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return -1;
    }
  }

  Future<Map<String, dynamic>?> _downloadJsonData(String filename) async {
    if (_config == null) return null;
    try {
      final remotePath = '${_config!.remotePath}$filename';

      LoggerService.instance.logSync('下载JSON数据', details: filename);

      final response = await _dio.get<String>(
        remotePath,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.data == null) return null;
      return jsonDecode(response.data!) as Map<String, dynamic>;
    } catch (e) {
      if (e is DioException && e.response?.statusCode == 404) {
        LoggerService.instance.logSync('JSON数据不存在(404)', details: filename);
        return null;
      }
      LoggerService.instance.logSync(
        '下载JSON数据失败: $filename, $e',
        level: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Map<String, dynamic>?> downloadManifest() => _downloadJsonData(_manifestFile);

  Future<bool> uploadManifest(Map<String, dynamic> manifest) async =>
      (await _uploadJsonData(manifest, _manifestFile)) >= 0;

  Future<Map<String, dynamic>?> downloadSnapshot() => _downloadJsonData(_snapshotFile);

  /// P1-13: 快照通常 MB 级，序列化走 isolate 避免阻塞 UI
  Future<int> uploadSnapshotSized(Map<String, dynamic> data) =>
      _uploadJsonData(data, _snapshotFile, useIsolate: true);

  Future<bool> uploadSnapshot(Map<String, dynamic> data) async =>
      (await uploadSnapshotSized(data)) >= 0;

  Future<Map<String, dynamic>?> downloadDelta() => _downloadJsonData(_deltaFile);

  Future<bool> uploadDelta(Map<String, dynamic> delta) async =>
      (await _uploadJsonData(delta, _deltaFile)) >= 0;

  Future<Map<String, dynamic>?> getLatestBackup() async {
    if (_config == null) return null;
    try {
      final snapshot = await downloadSnapshot();
      if (snapshot != null) {
        LoggerService.instance.logSync('使用新格式快照恢复');
        return snapshot;
      }

      final files = await propFind(_config!.remotePath);
      final backupFiles = files
          .map((f) => Uri.decodeFull(f))
          .where((f) => f.contains('qnote_backup_') && f.endsWith('.json'))
          .toList();
      if (backupFiles.isEmpty) {
        LoggerService.instance.logSync('未找到备份文件', level: LogLevel.warning);
        return null;
      }
      backupFiles.sort((a, b) => b.compareTo(a));
      final latestPath = backupFiles.first;
      final filename = latestPath.split('/').last;
      final remotePath = '${_config!.remotePath}$filename';

      LoggerService.instance.logSync('使用旧格式备份恢复', details: filename);

      final response = await _dio.get<String>(
        remotePath,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.data == null) return null;
      return jsonDecode(response.data!) as Map<String, dynamic>;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '获取最新备份失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return null;
    }
  }

  Future<SyncResult> uploadDatabase({bool forceFullSync = false}) async {
    if (_config == null) {
      return SyncResult(success: false, error: 'WebDAV未配置');
    }

    try {
      LoggerService.instance.logSync('开始同步上传...');

      final syncLog = SyncLogRepository.instance;
      final changeCount = await syncLog.getChangeCount();

      if (changeCount == 0 && !forceFullSync) {
        LoggerService.instance.logSync('无变更，跳过同步');
        return SyncResult(success: true, changeCount: 0);
      }

      await createRemoteDirectory();

      final configRepo = ConfigRepository.instance;
      final deltaCountStr = await configRepo.getAppConfig('sync_delta_count') ?? '0';
      int deltaCount = int.tryParse(deltaCountStr) ?? 0;

      final remoteManifest = await downloadManifest();
      final hasRemoteSnapshot = remoteManifest != null;

      if (forceFullSync || !hasRemoteSnapshot || deltaCount >= _maxDeltaCount) {
        return await _performFullUpload(syncLog, configRepo, deltaCount);
      } else {
        return await _performDeltaUpload(syncLog, configRepo, deltaCount);
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '同步上传失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return SyncResult(success: false, error: e.toString());
    }
  }

  Future<SyncResult> _performFullUpload(
    SyncLogRepository syncLog,
    ConfigRepository configRepo,
    int currentDeltaCount,
  ) async {
    LoggerService.instance.logSync('执行全量快照上传...');

    // P1-13: 直接拿 Map 而非 String，消除「exportAllToJson 内 encode →
    // 此处 jsonDecode → uploadSnapshot 内再 encode」的三重序列化反模式。
    final exportService = ExportService();
    final data = await exportService.exportAllToMap(includeImages: false);

    final now = DateTime.now();
    final snapshotVersion = (currentDeltaCount + 1);

    data['snapshot_version'] = snapshotVersion;
    data['snapshot_time'] = now.toIso8601String();

    // P1-13: 快照序列化走 isolate，uploadSnapshotSized 内部用 compute
    // 完成大 JSON 编码，返回字节数避免此处重复 encode 算 uploadSize。
    final uploadSize = await uploadSnapshotSized(data);
    if (uploadSize < 0) {
      return SyncResult(success: false, error: '快照上传失败');
    }

    await deleteFile(_deltaFile);

    final manifest = {
      'format_version': 1,
      'last_sync_time': now.toIso8601String(),
      'snapshot_time': now.toIso8601String(),
      'snapshot_version': snapshotVersion,
      'delta_count': 0,
      'has_delta': false,
    };
    await uploadManifest(manifest);

    await syncLog.clearAll();
    await configRepo.setAppConfig('sync_delta_count', '0');
    await configRepo.setAppConfig('sync_last_snapshot_time', now.toIso8601String());

    LoggerService.instance.logSync(
      '全量快照上传成功',
      details: '版本=$snapshotVersion, 大小≈${(uploadSize / 1024).toStringAsFixed(1)}KB',
    );

    return SyncResult(
      success: true,
      wasFullSync: true,
      changeCount: 0,
      uploadSizeBytes: uploadSize,
    );
  }

  Future<SyncResult> _performDeltaUpload(
    SyncLogRepository syncLog,
    ConfigRepository configRepo,
    int currentDeltaCount,
  ) async {
    LoggerService.instance.logSync('执行增量上传...');

    var delta = await syncLog.buildDeltaJson();
    final changes = delta['changes'] as Map<String, dynamic>? ?? {};
    if (changes.isEmpty) {
      LoggerService.instance.logSync('无实际变更，跳过增量上传');
      await syncLog.clearAll();
      return SyncResult(success: true, changeCount: 0);
    }

    final now = DateTime.now();
    final remoteManifest = await downloadManifest();
    final baseSnapshotVersion = remoteManifest?['snapshot_version'] ?? 1;
    final hasDelta = remoteManifest?['has_delta'] == true;

    delta['delta_time'] = now.toIso8601String();
    delta['base_snapshot_version'] = baseSnapshotVersion;

    Map<String, dynamic>? existingDelta;
    if (hasDelta) {
      existingDelta = await downloadDelta();
    }
    
    if (existingDelta != null) {
      delta = _mergeDeltas(existingDelta, delta);
    }

    // P1-13: 直接复用 _uploadJsonData 返回的字节数，避免此处再 encode 一次算 uploadSize
    final uploadSize = await _uploadJsonData(delta, _deltaFile);
    if (uploadSize < 0) {
      return SyncResult(success: false, error: '增量数据上传失败');
    }

    final newDeltaCount = currentDeltaCount + 1;

    final manifest = {
      'format_version': 1,
      'last_sync_time': now.toIso8601String(),
      'snapshot_time': remoteManifest?['snapshot_time'] ?? now.toIso8601String(),
      'snapshot_version': baseSnapshotVersion,
      'delta_count': newDeltaCount,
      'has_delta': true,
    };
    await uploadManifest(manifest);

    await syncLog.clearAll();
    await configRepo.setAppConfig('sync_delta_count', newDeltaCount.toString());

    final changeCount = await syncLog.getChangeCount();

    LoggerService.instance.logSync(
      '增量上传成功',
      details: '变更=$changeCount, 大小≈${(uploadSize / 1024).toStringAsFixed(1)}KB, 增量次数=$newDeltaCount',
    );

    return SyncResult(
      success: true,
      wasFullSync: false,
      changeCount: changeCount,
      uploadSizeBytes: uploadSize,
    );
  }

  Map<String, dynamic> _mergeDeltas(
    Map<String, dynamic> existing,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(existing);
    final existingChanges = Map<String, dynamic>.from(merged['changes'] as Map? ?? {});
    final incomingChanges = Map<String, dynamic>.from(incoming['changes'] as Map? ?? {});

    for (final tableName in incomingChanges.keys) {
      final incomingTable = Map<String, dynamic>.from(incomingChanges[tableName] as Map);
      if (existingChanges.containsKey(tableName)) {
        final existingTable = Map<String, dynamic>.from(existingChanges[tableName] as Map);

        final existingUpserts = List<Map<String, dynamic>>.from(
          (existingTable['upserts'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? [],
        );
        final incomingUpserts = List<Map<String, dynamic>>.from(
          (incomingTable['upserts'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? [],
        );

        final existingDeletes = List<String>.from(existingTable['deletes'] as List? ?? []);
        final incomingDeletes = List<String>.from(incomingTable['deletes'] as List? ?? []);

        final upsertMap = <String, Map<String, dynamic>>{};
        for (final upsert in existingUpserts) {
          final id = upsert['id']?.toString() ?? upsert['key']?.toString();
          if (id != null) upsertMap[id] = upsert;
        }
        for (final upsert in incomingUpserts) {
          final id = upsert['id']?.toString() ?? upsert['key']?.toString();
          if (id != null) upsertMap[id] = upsert;
        }

        final deleteSet = <String>{...existingDeletes, ...incomingDeletes};
        upsertMap.removeWhere((id, _) => deleteSet.contains(id));

        existingChanges[tableName] = {
          'upserts': upsertMap.values.toList(),
          'deletes': deleteSet.toList(),
        };
      } else {
        existingChanges[tableName] = incomingTable;
      }
    }

    merged['changes'] = existingChanges;
    merged['delta_time'] = incoming['delta_time'];

    final existingImageChanges = Map<String, dynamic>.from(merged['image_changes'] as Map? ?? {});
    final incomingImageChanges = Map<String, dynamic>.from(incoming['image_changes'] as Map? ?? {});

    final addedImages = <String>{
      ...List<String>.from(existingImageChanges['added'] as List? ?? []),
      ...List<String>.from(incomingImageChanges['added'] as List? ?? []),
    };
    final deletedImages = <String>{
      ...List<String>.from(existingImageChanges['deleted'] as List? ?? []),
      ...List<String>.from(incomingImageChanges['deleted'] as List? ?? []),
    };
    addedImages.removeAll(deletedImages);

    merged['image_changes'] = {
      'added': addedImages.toList(),
      'deleted': deletedImages.toList(),
    };

    return merged;
  }

  Future<bool> downloadDatabase({bool merge = false}) async {
    if (_config == null) return false;
    try {
      LoggerService.instance.logSync(
        '开始下载数据库备份',
        details: merge ? '合并模式' : '覆盖模式',
      );

      final manifest = await downloadManifest();
      final exportService = ExportService();

      if (manifest != null) {
        final snapshot = await downloadSnapshot();
        if (snapshot == null) {
          LoggerService.instance.logSync('快照下载失败', level: LogLevel.error);
          return false;
        }

        await exportService.importFromJsonString(
          jsonEncode(snapshot),
          overwrite: !merge,
        );

        final hasDelta = manifest['has_delta'] == true;
        if (hasDelta) {
          final delta = await downloadDelta();
          if (delta != null) {
            await exportService.applyDeltaFromJson(jsonEncode(delta));
            LoggerService.instance.logSync('增量变更已应用');
          }
        }
      } else {
        final backup = await getLatestBackup();
        if (backup == null) {
          LoggerService.instance.logSync('未找到任何备份数据', level: LogLevel.warning);
          return false;
        }
        await exportService.importFromJsonString(
          jsonEncode(backup),
          overwrite: !merge,
        );
      }

      final syncLog = SyncLogRepository.instance;
      await syncLog.clearAll();
      await ConfigRepository.instance.setAppConfig('sync_delta_count', '0');

      LoggerService.instance.logSync('数据库备份恢复成功');
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '数据库备份恢复失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  Future<int> cleanupOldBackupFiles() async {
    if (_config == null) return 0;
    try {
      final files = await propFind(_config!.remotePath);
      final oldBackupFiles = files
          .map((f) => Uri.decodeFull(f))
          .where((f) => f.contains('qnote_backup_') && f.endsWith('.json'))
          .toList();

      int deletedCount = 0;
      for (final filePath in oldBackupFiles) {
        final filename = filePath.split('/').last;
        final success = await deleteFile(filename);
        if (success) deletedCount++;
      }

      LoggerService.instance.logSync(
        '清理旧备份文件完成',
        details: '删除 $deletedCount/${oldBackupFiles.length} 个文件',
      );

      return deletedCount;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '清理旧备份文件失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return 0;
    }
  }

  Future<String> getDatabasesPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'databases');
  }

  Future<Set<String>> _getActiveImagesFromDb() async {
    final activeImages = <String>{};
    try {
      final db = await DatabaseHelper.instance.database;

      // 1. 日记图片
      final diaries = await db.query('diary_records');
      for (final row in diaries) {
        final photosStr = row['photos'] as String?;
        if (photosStr != null && photosStr.isNotEmpty) {
          try {
            final photos = jsonDecode(photosStr);
            if (photos is List) {
              for (final p in photos) {
                final rel = _toRelativeImagePath(p.toString());
                if (rel != null) activeImages.add(rel);
              }
            }
          } catch (_) {}
        }
      }

      // 2. 笔记图片
      final notes = await db.query('notes');
      for (final row in notes) {
        final imagesStr = row['images'] as String?;
        if (imagesStr != null && imagesStr.isNotEmpty) {
          try {
            final images = jsonDecode(imagesStr);
            if (images is List) {
              for (final img in images) {
                final rel = _toRelativeImagePath(img.toString());
                if (rel != null) activeImages.add(rel);
              }
            }
          } catch (_) {}
        }
      }

      // 3. 用户头像
      final profiles = await db.query('user_profiles');
      for (final row in profiles) {
        final avatar = row['avatar_path'] as String?;
        if (avatar != null && avatar.isNotEmpty) {
          final rel = _toRelativeImagePath(avatar);
          if (rel != null) activeImages.add(rel);
        }
      }
    } catch (e) {
      LoggerService.instance.logSync('获取数据库活动图片失败: $e', level: LogLevel.warning);
    }
    return activeImages;
  }

  String? _toRelativeImagePath(String absolutePath) {
    if (absolutePath.isEmpty) return null;
    final normalized = absolutePath.replaceAll('\\', '/');
    final imagesIndex = normalized.lastIndexOf('/images/');
    if (imagesIndex != -1) {
      return absolutePath.substring(imagesIndex + 8);
    }
    return null;
  }

  Future<bool> syncImages({Function(String status)? onProgress}) async {
    if (_config == null) return false;

    try {
      onProgress?.call('正在扫描本地及云端图片...');
      LoggerService.instance.logSync('开始 WebDAV 图片同步...');

      // 1. 获取本地数据库中所有被引用的“活动图片”
      final activeImages = await _getActiveImagesFromDb();
      
      // 2. 获取本地磁盘上 images/ 目录下所有物理存在的图片
      final appDir = await getApplicationDocumentsDirectory();
      final localImagesDir = Directory(p.join(appDir.path, 'images'));
      final localPhysicalImages = <String>{};
      if (await localImagesDir.exists()) {
        final files = await localImagesDir.list(recursive: true).where((f) => f is File).cast<File>().toList();
        for (final f in files) {
          final rel = _toRelativeImagePath(f.path);
          if (rel != null) {
            localPhysicalImages.add(rel);
          }
        }
      }

      // 3. 列出云端 images 目录下的图片
      // 确保云端 images 目录存在
      final remoteImagesBase = '${_config!.remotePath}images/';
      try {
        await _dio.request(remoteImagesBase, options: Options(method: 'MKCOL'));
      } catch (_) {}

      // 获取云端所有的图片相对路径
      final remoteImages = <String>{};
      
      // 递归获取云端 images 文件夹下的所有文件
      final subfolders = ['diary', 'notes', 'avatar'];
      for (final sub in subfolders) {
        final remoteSubDir = '$remoteImagesBase$sub/';
        try {
          await _dio.request(remoteSubDir, options: Options(method: 'MKCOL'));
        } catch (_) {}

        final filesInSub = await propFind(remoteSubDir);
        for (final fileHref in filesInSub) {
          final decodedHref = Uri.decodeFull(fileHref);
          final fileName = decodedHref.split('/').last;
          if (fileName.isNotEmpty) {
            remoteImages.add('$sub/$fileName');
          }
        }
      }

      LoggerService.instance.logSync('图片扫描结果: 本地引用=${activeImages.length}, 本地磁盘=${localPhysicalImages.length}, 云端=${remoteImages.length}');

      // 4. 上传逻辑：本地物理存在且被数据库引用，且云端不存在 -> 上传
      final uploadTargets = activeImages.intersection(localPhysicalImages).difference(remoteImages);
      int uploadCount = 0;
      for (final rel in uploadTargets) {
        onProgress?.call('正在上传图片: ${uploadCount + 1}/${uploadTargets.length}');
        final localPath = p.join(appDir.path, 'images', rel);
        final remoteName = 'images/$rel';
        
        // 确保云端子文件夹存在
        final parentDir = p.dirname(rel);
        if (parentDir != '.') {
          try {
            await _dio.request('$remoteImagesBase$parentDir/', options: Options(method: 'MKCOL'));
          } catch (_) {}
        }

        final success = await uploadFile(localPath, remoteName);
        if (success) uploadCount++;
      }

      // 5. 下载逻辑：数据库引用但本地物理不存在，且云端存在 -> 下载
      final downloadTargets = activeImages.difference(localPhysicalImages).intersection(remoteImages);
      int downloadCount = 0;
      for (final rel in downloadTargets) {
        onProgress?.call('正在下载图片: ${downloadCount + 1}/${downloadTargets.length}');
        final localPath = p.join(appDir.path, 'images', rel);
        final remoteName = 'images/$rel';
        final success = await downloadFile(remoteName, localPath);
        if (success) downloadCount++;
      }

      // 6. 删除逻辑：云端存在但本地数据库不引用，且本地物理也不存在（或者已被用户删除） -> 从云端删除
      final deleteFromRemoteTargets = remoteImages.difference(activeImages);
      int deleteCount = 0;
      for (final rel in deleteFromRemoteTargets) {
        onProgress?.call('正在清理云端旧图片: ${deleteCount + 1}/${deleteFromRemoteTargets.length}');
        final success = await deleteFile('images/$rel');
        if (success) deleteCount++;
      }

      // 7. 清理本地物理存在的、但在数据库中没有引用的图片
      final localCleanupTargets = localPhysicalImages.difference(activeImages);
      for (final rel in localCleanupTargets) {
        final localPath = p.join(appDir.path, 'images', rel);
        try {
          await File(localPath).delete();
        } catch (_) {}
      }

      LoggerService.instance.logSync('图片同步完成! 上传=$uploadCount, 下载=$downloadCount, 清理云端=$deleteCount, 清理本地=${localCleanupTargets.length}');
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync('图片同步失败: $e', level: LogLevel.error, details: stackTrace.toString());
      return false;
    }
  }
}
