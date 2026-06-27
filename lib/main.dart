import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'database_init.dart' if (dart.library.io) 'database_init_io.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/network/sync_scheduler.dart';
import 'package:qnote_flutter/core/notification/notification_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));
  await LoggerService.instance.init();
  await initializeDateFormatting('zh_CN');
  await initDatabaseFactory();
  await DatabaseHelper.instance.database;
  final configRepo = ConfigRepository.instance;
  await Future.wait([
    configRepo.ensureDefaultShortcuts(),
    configRepo.ensureDefaultAiConfigs(),
    AiRoleService.instance.initAndEnsureDefaults(),
    NotificationService.instance.init(),
  ]);
  final webdavConfig = await configRepo.getWebdavConfig();
  if (webdavConfig != null && webdavConfig.autoSync) {
    SyncScheduler.instance.syncIfNeeded();
  }
  NotificationService.instance.startReminderCheck();
  runApp(const ProviderScope(child: QNoteApp()));
}
