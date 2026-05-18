import 'dart:async';
import 'package:qnote_flutter/core/network/webdav_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';

enum SyncStatus { idle, syncing, success, error }

class SyncScheduler {
  static final SyncScheduler _instance = SyncScheduler._();
  static SyncScheduler get instance => _instance;
  SyncScheduler._();

  final WebdavService _webdavService = WebdavService.instance;
  final ConfigRepository _configRepo = ConfigRepository.instance;

  SyncStatus _status = SyncStatus.idle;
  SyncStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  DateTime? _lastSyncTime;
  DateTime? get lastSyncTime => _lastSyncTime;

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
    await performSync();
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
      await _webdavService.uploadDatabase();
      _lastSyncTime = DateTime.now();
      final updatedConfig = config.copyWith(
        lastSyncTime: _lastSyncTime,
      );
      await _configRepo.upsertWebdavConfig(updatedConfig);
      _updateStatus(SyncStatus.success);
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(SyncStatus.error);
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
      await _webdavService.downloadDatabase(merge: merge);
      _lastSyncTime = DateTime.now();
      _updateStatus(SyncStatus.success);
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(SyncStatus.error);
    }
  }

  void dispose() {
    _periodicTimer?.cancel();
    _statusController.close();
  }
}
