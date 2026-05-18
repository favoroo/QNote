import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/webdav_config.dart';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class WebdavService {
  static final WebdavService _instance = WebdavService._();
  static WebdavService get instance => _instance;
  WebdavService._();

  final Dio _dio = Dio();
  WebdavConfig? _config;

  WebdavConfig? get config => _config;

  void updateConfig(WebdavConfig config) {
    // Normalize serverUrl to end with a slash
    var serverUrl = config.serverUrl.trim();
    if (!serverUrl.endsWith('/')) {
      serverUrl = '$serverUrl/';
    }

    // Normalize remotePath: strip leading slashes and ensure a trailing slash
    var remotePath = config.remotePath.trim();
    while (remotePath.startsWith('/')) {
      remotePath = remotePath.substring(1);
    }
    if (remotePath.isNotEmpty && !remotePath.endsWith('/')) {
      remotePath = '$remotePath/';
    }

    // Store config with normalized paths
    _config = config.copyWith(
      serverUrl: serverUrl,
      remotePath: remotePath,
    );

    _dio.options.baseUrl = serverUrl;
    _dio.options.headers['Authorization'] =
        'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}';
    
    LoggerService.instance.logNetwork(
      '更新WebDAV配置',
      details: '服务器=$serverUrl, 路径=$remotePath'
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
        level: success ? LogLevel.info : LogLevel.warning
      );
      
      return success;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        'WebDAV连接测试异常: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
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
          details: localPath
        );
        return false;
      }
      
      final bytes = await file.readAsBytes();
      final remotePath = '${_config!.remotePath}$remoteName';
      
      LoggerService.instance.logNetwork(
        '开始上传文件',
        details: '$localPath -> $remoteName, 大小≈${(bytes.length / 1024).toStringAsFixed(1)}KB'
      );
      
      await _dio.put(remotePath, data: Stream.fromIterable([bytes]));
      
      LoggerService.instance.logNetwork('文件上传成功', details: remoteName);
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '文件上传失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
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
        details: '$remoteName -> $localPath'
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
        details: '$remoteName, 大小≈${(response.data!.length / 1024).toStringAsFixed(1)}KB'
      );
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '文件下载失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
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
        details: '找到 ${files.length} 个文件'
      );
      
      return files;
    } catch (e, stackTrace) {
      LoggerService.instance.logNetwork(
        '列出远程文件失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
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
      LoggerService.instance.logNetwork(
        '删除远程文件失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
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
        details: stackTrace.toString()
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

  Future<bool> syncData(Map<String, dynamic> data, String filename) async {
    if (_config == null) return false;
    try {
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      final bytes = utf8.encode(jsonStr);
      final remotePath = '${_config!.remotePath}$filename';
      
      LoggerService.instance.logSync(
        '同步数据到云端',
        details: '文件=$filename, 大小≈${(bytes.length / 1024).toStringAsFixed(1)}KB'
      );
      
      await _dio.put(
        remotePath,
        data: Stream.fromIterable([bytes]),
        options: Options(contentType: 'application/json'),
      );
      
      LoggerService.instance.logSync('数据同步成功');
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '数据同步失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
      );
      return false;
    }
  }

  Future<Map<String, dynamic>?> getLatestBackup() async {
    if (_config == null) return null;
    try {
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
      
      LoggerService.instance.logSync('获取最新备份', details: filename);
      
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
        details: stackTrace.toString()
      );
      return null;
    }
  }

  Future<bool> uploadDatabase() async {
    if (_config == null) return false;
    try {
      LoggerService.instance.logSync('开始上传数据库备份...');
      
      final exportService = ExportService();
      final jsonStr = await exportService.exportAllToJson();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final now = DateTime.now();
      final filename =
          'qnote_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}.json';
      final result = await syncData(data, filename);
      
      if (result) {
        LoggerService.instance.logSync('数据库备份上传成功', details: filename);
      }
      
      return result;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '数据库备份上传失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
      );
      return false;
    }
  }

  Future<bool> downloadDatabase({bool merge = false}) async {
    if (_config == null) return false;
    try {
      LoggerService.instance.logSync(
        '开始下载数据库备份',
        details: merge ? '合并模式' : '覆盖模式'
      );
      
      final backup = await getLatestBackup();
      if (backup == null) return false;
      final exportService = ExportService();
      await exportService.importFromJsonString(
        jsonEncode(backup),
        overwrite: !merge,
      );
      
      LoggerService.instance.logSync('数据库备份恢复成功');
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logSync(
        '数据库备份恢复失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString()
      );
      return false;
    }
  }

  Future<String> getDatabasesPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'databases');
  }
}
