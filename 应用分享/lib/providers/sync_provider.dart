import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/network/webdav_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart' show SyncScheduler, SyncStatus;
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/webdav_config.dart';

final webdavServiceProvider = Provider<WebdavService>((ref) {
  return WebdavService.instance;
});

final webdavConfigProvider = AsyncNotifierProvider<WebdavConfigNotifier, WebdavConfig?>(WebdavConfigNotifier.new);

class WebdavConfigNotifier extends AsyncNotifier<WebdavConfig?> {
  @override
  Future<WebdavConfig?> build() async {
    final repo = ConfigRepository();
    return repo.getWebdavConfig();
  }

  Future<void> refresh() async {
    final repo = ConfigRepository();
    state = AsyncData(await repo.getWebdavConfig());
  }

  Future<void> saveConfig(WebdavConfig config) async {
    final repo = ConfigRepository();
    await repo.upsertWebdavConfig(config);
    final service = ref.read(webdavServiceProvider);
    service.updateConfig(config);
    await refresh();
  }

  Future<void> deleteConfig(String id) async {
    final repo = ConfigRepository();
    await repo.deleteWebdavConfig(id);
    await refresh();
  }

  Future<bool> testConnection() async {
    final service = ref.read(webdavServiceProvider);
    return service.testConnection();
  }
}

final syncStatusProvider = StateProvider<SyncStatus>((ref) => SyncStatus.idle);

final syncProvider = AsyncNotifierProvider<SyncNotifier, void>(SyncNotifier.new);

class SyncNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<void> syncToRemote() async {
    ref.read(syncStatusProvider.notifier).state = SyncStatus.syncing;
    try {
      final scheduler = SyncScheduler.instance;
      await scheduler.performSync();
      ref.read(syncStatusProvider.notifier).state = scheduler.status;
    } catch (_) {
      ref.read(syncStatusProvider.notifier).state = SyncStatus.error;
    }
  }

  Future<void> syncFromRemote() async {
    ref.read(syncStatusProvider.notifier).state = SyncStatus.syncing;
    try {
      final scheduler = SyncScheduler.instance;
      await scheduler.restoreFromBackup();
      ref.read(syncStatusProvider.notifier).state = scheduler.status;
    } catch (_) {
      ref.read(syncStatusProvider.notifier).state = SyncStatus.error;
    }
  }

  Future<void> fullSyncToRemote() async {
    ref.read(syncStatusProvider.notifier).state = SyncStatus.syncing;
    try {
      final scheduler = SyncScheduler.instance;
      await scheduler.fullSync();
      ref.read(syncStatusProvider.notifier).state = scheduler.status;
    } catch (_) {
      ref.read(syncStatusProvider.notifier).state = SyncStatus.error;
    }
  }

  void resetStatus() {
    ref.read(syncStatusProvider.notifier).state = SyncStatus.idle;
  }
}
