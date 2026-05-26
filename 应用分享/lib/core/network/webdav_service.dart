import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

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

  Future<bool> _uploadJsonData(Map<String, dynamic> data, String filename) async {
    if (_config == null) return false;
    try {
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      final bytes = utf8.encode(jsonStr);
      final remotePath = '${_config!.remotePath}$filename';

      LoggerService.instance.logSync(
        '上传JSON数据',
        details: '文件=$filename, 大小≈${(bytes.length / 1024).toStringAsFixed(1)}KB',
      );

      await _dio.put(
        remotePath,
        data: Stream.fromIterable([bytes]),
        options: Options(contentType: 'application/json'),
      );

      LoggerService.instance.logSync('JSON数据上传成功', details: filename);
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        'JSON数据上传失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      return false;
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

  Future<bool> uploadManifest(Map<String, dynamic> manifest) => _uploadJsonData(manifest, _manifestFile);

  Future<Map<String, dynamic>?> downloadSnapshot() => _downloadJsonData(_snapshotFile);

  Future<bool> uploadSnapshot(Map<String, dynamic> data) => _uploadJsonData(data, _snapshotFile);

  Future<Map<String, dynamic>?> downloadDelta() => _downloadJsonData(_deltaFile);

  Future<bool> uploadDelta(Map<String, dynamic> delta) => _uploadJsonData(delta, _deltaFile);

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

    final exportService = ExportService();
    final jsonStr = await exportService.exportAllToJson(includeImages: false);
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    final now = DateTime.now();
    final snapshotVersion = (currentDeltaCount + 1);

    data['snapshot_version'] = snapshotVersion;
    data['snapshot_time'] = now.toIso8601String();

    final jsonBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(data));
    final uploadSize = jsonBytes.length;

    final snapshotResult = await uploadSnapshot(data);
    if (!snapshotResult) {
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

    final jsonBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(delta));
    final uploadSize = jsonBytes.length;

    final deltaResult = await uploadDelta(delta);
    if (!deltaResult) {
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
}
