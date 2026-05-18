import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'app.dart';
import 'database_init.dart' if (dart.library.io) 'database_init_io.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  await initDatabaseFactory();
  await DatabaseHelper.instance.database;
  final configRepo = ConfigRepository.instance;
  await configRepo.ensureDefaultShortcuts();
  await configRepo.ensureDefaultAiConfigs();
  await NotificationService.instance.init();
  await LoggerService.instance.init();
  final webdavConfig = await configRepo.getWebdavConfig();
  if (webdavConfig != null && webdavConfig.autoSync) {
    SyncScheduler.instance.syncIfNeeded();
  }
  NotificationService.instance.startReminderCheck();
  runApp(const ProviderScope(child: QNoteApp()));
}
