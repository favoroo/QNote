import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoggerService 限制与管理测试', () {
    late LoggerService logger;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      logger = LoggerService.instance;
      await logger.clearLogs();
    });

    test('连续记录日志最多只保留最近 35 条，超出部分 FIFO 淘汰', () {
      for (var i = 0; i < 50; i++) {
        logger.info('Test log entry $i');
      }

      expect(logger.entries.length, 35);
      // 第 0 项为保留的第一条（即序号 15）
      expect(logger.entries.first.message.contains('Test log entry 15'), isTrue);
      // 最后一项为最新产生的一条（即序号 49）
      expect(logger.entries.last.message.contains('Test log entry 49'), isTrue);
    });

    test('从本地存储恢复超过 35 条的历史数据时，自动截断保留最新 35 条', () async {
      final oldLogs = List.generate(
        60,
        (i) => {
          'timestamp': DateTime.now().add(Duration(seconds: i)).toIso8601String(),
          'message': 'Persisted log $i',
          'level': 0,
        },
      );

      SharedPreferences.setMockInitialValues({
        'qnote_logs': jsonEncode(oldLogs),
      });

      await logger.loadLogs();

      expect(logger.entries.length, 35);
      expect(logger.entries.first.message, 'Persisted log 25');
      expect(logger.entries.last.message, 'Persisted log 59');
    });

    test('clearLogs 成功清空日志并保留一条日志已清除记录', () async {
      logger.info('log 1');
      logger.warning('log 2');
      expect(logger.entries.isNotEmpty, isTrue);

      await logger.clearLogs();
      // clearLogs 会清空旧日志并写入一条系统日志“日志已清除”
      expect(logger.entries.length, 1);
      expect(logger.entries.first.message.contains('日志已清除'), isTrue);
    });
  });
}
