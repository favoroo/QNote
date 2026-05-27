import 'dart:async';
import 'package:qnote_flutter/core/network/webdav_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';

enum SyncStatus { idle, syncing, success, error }

class SyncScheduler {
  static final SyncScheduler _instance = SyncScheduler._();
  static SyncScheduler get instance => _instance;
  SyncScheduler._();

  final WebdavService _webdavService = WebdavService.instance;
  final ConfigRepository _configRepo = ConfigRepository.instance;

  SyncStatus _status = SyncStatus.idle;
  SyncStatus get status => _status;

  String? _currentProgressStatus;
  String? get currentProgressStatus => _currentProgressStatus;

  String? _lastError;
  String? get lastError => _lastError;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

  bool _lastSyncWasFull = false;
  bool get lastSyncWasFull => _lastSyncWasFull;

  int? _lastSyncSizeBytes;
  int? get lastSyncSizeBytes => _lastSyncSizeBytes;

  int _pendingChanges = 0;
  int get pendingChanges => _pendingChanges;

  Timer? _periodicTimer;

  final _statusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _statusController.stream;

  void _updateStatus(SyncStatus status) {
    _status = status;
    _statusController.add(status);
  }

  Future<void> syncIfNeeded() async {
    final config = await _configRepo.getWebdavConfig();
    if (config == null || !config.autoSync) return;
    _webdavService.updateConfig(config);

    final syncOnLaunchStr = await _configRepo.getAppConfig('webdav_sync_on_launch');
    final syncOnLaunch = syncOnLaunchStr == 'true';
    if (syncOnLaunch) {
      await performSync();
    }

    _setupPeriodicSync(config.syncInterval);
  }

  void _setupPeriodicSync(int intervalMinutes) {
    _periodicTimer?.cancel();
    if (intervalMinutes <= 0) return;
    _periodicTimer = Timer.periodic(
      Duration(minutes: intervalMinutes),
      (_) => performSync(),
    );
  }

  Future<void> performSync() async {
    if (_status == SyncStatus.syncing) return;
    _updateStatus(SyncStatus.syncing);
    _lastError = null;
    try {
      final config = await _configRepo.getWebdavConfig();
      if (config == null) throw Exception('WebDAV not configured');
      _webdavService.updateConfig(config);

      await _refreshPendingChanges();

      final result = await _webdavService.uploadDatabase();
      if (!result.success) {
        throw Exception(result.error ?? '备份上传失败，请查看运行日志获取详情');
      }
      _lastSyncTime = DateTime.now();
      _lastSyncWasFull = result.wasFullSync;
      _lastSyncSizeBytes = result.uploadSizeBytes;

      final updatedConfig = config.copyWith(
        lastSyncTime: _lastSyncTime,
      );
      await _configRepo.upsertWebdavConfig(updatedConfig);

      final syncImagesEnabled = await _configRepo.getAppConfig('webdav_sync_images') == 'true';
      if (syncImagesEnabled) {
        _currentProgressStatus = '数据同步已完成，正在同步图片...';
        _statusController.add(_status);
        final imgSuccess = await _webdavService.syncImages(
          onProgress: (progress) {
            _currentProgressStatus = progress;
            _statusController.add(_status);
          },
        );
        if (!imgSuccess) {
          throw Exception('数据备份成功，但图片同步失败');
        }
      }

      await _refreshPendingChanges();
      _updateStatus(SyncStatus.success);
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(SyncStatus.error);
    } finally {
      _currentProgressStatus = null;
    }
  }

  Future<void> fullSync() async {
    if (_status == SyncStatus.syncing) return;
    _updateStatus(SyncStatus.syncing);
    _lastError = null;
    try {
      final config = await _configRepo.getWebdavConfig();
      if (config == null) throw Exception('WebDAV not configured');
      _webdavService.updateConfig(config);

      final result = await _webdavService.uploadDatabase(forceFullSync: true);
      if (!result.success) {
        throw Exception(result.error ?? '全量同步失败，请查看运行日志获取详情');
      }
      _lastSyncTime = DateTime.now();
      _lastSyncWasFull = true;
      _lastSyncSizeBytes = result.uploadSizeBytes;

      final updatedConfig = config.copyWith(
        lastSyncTime: _lastSyncTime,
      );
      await _configRepo.upsertWebdavConfig(updatedConfig);

      final syncImagesEnabled = await _configRepo.getAppConfig('webdav_sync_images') == 'true';
      if (syncImagesEnabled) {
        _currentProgressStatus = '全量数据同步已完成，正在同步图片...';
        _statusController.add(_status);
        final imgSuccess = await _webdavService.syncImages(
          onProgress: (progress) {
            _currentProgressStatus = progress;
            _statusController.add(_status);
          },
        );
        if (!imgSuccess) {
          throw Exception('全量数据同步成功，但图片同步失败');
        }
      }

      await _refreshPendingChanges();
      _updateStatus(SyncStatus.success);
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(SyncStatus.error);
    } finally {
      _currentProgressStatus = null;
    }
  }

  Future<void> manuallySyncImages({Function(String status)? onProgress}) async {
    if (_status == SyncStatus.syncing) return;
    _updateStatus(SyncStatus.syncing);
    _lastError = null;
    try {
      final config = await _configRepo.getWebdavConfig();
      if (config == null) throw Exception('WebDAV not configured');
      _webdavService.updateConfig(config);

      _currentProgressStatus = '开始同步图片...';
      _statusController.add(_status);

      final success = await _webdavService.syncImages(
        onProgress: (status) {
          _currentProgressStatus = status;
          onProgress?.call(status);
          _statusController.add(_status);
        },
      );

      if (!success) {
        throw Exception('图片同步失败，请检查连接或查看日志');
      }

      _lastSyncTime = DateTime.now();
      _updateStatus(SyncStatus.success);
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(SyncStatus.error);
    } finally {
      _currentProgressStatus = null;
    }
  }

  Future<void> restoreFromBackup({bool merge = false}) async {
    if (_status == SyncStatus.syncing) return;
    _updateStatus(SyncStatus.syncing);
    _lastError = null;
    try {
      final config = await _configRepo.getWebdavConfig();
      if (config == null) throw Exception('WebDAV not configured');
      _webdavService.updateConfig(config);
      final success = await _webdavService.downloadDatabase(merge: merge);
      if (!success) {
        throw Exception('备份下载/恢复失败，请确认云端是否存在备份，或查看运行日志');
      }
      _lastSyncTime = DateTime.now();
      await _refreshPendingChanges();
      _updateStatus(SyncStatus.success);
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(SyncStatus.error);
    }
  }

  Future<int> cleanupRemoteBackups() async {
    final config = await _configRepo.getWebdavConfig();
    if (config == null) return 0;
    _webdavService.updateConfig(config);
    return _webdavService.cleanupOldBackupFiles();
  }

  Future<void> _refreshPendingChanges() async {
    try {
      _pendingChanges = await SyncLogRepository.instance.getChangeCount();
    } catch (_) {
      _pendingChanges = 0;
    }
  }

  void dispose() {
    _periodicTimer?.cancel();
    _statusController.close();
  }
}
