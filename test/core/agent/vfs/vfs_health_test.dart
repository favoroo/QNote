import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final vfs = VirtualWorkspaceService.instance;
  final healthRepo = HealthMetricRepository(DatabaseHelper.instance);

  group('VFS /health/ 虚拟路径测试', () {
    test('listDir /health 列出 summary.json 及对应日期文件', () async {
      await healthRepo.upsertDailyMetrics(HealthDailyMetrics(
        date: '2026-09-15',
        steps: 8888,
        distanceMeters: 6200.0,
        calories: 320.0,
        updatedAt: DateTime.now(),
      ));

      final rootFiles = await vfs.listDir('/');
      expect(rootFiles, contains('health/'));

      final healthFiles = await vfs.listDir('/health');
      expect(healthFiles, contains('summary.json'));
      expect(healthFiles, contains('2026-09-15.json'));
    });

    test('readFile /health/2026-09-15.json 能够正确读取步数与健康指标', () async {
      await healthRepo.upsertDailyMetrics(HealthDailyMetrics(
        date: '2026-09-15',
        steps: 9500,
        distanceMeters: 7000.0,
        calories: 400.0,
        sleepDurationMinutes: 480,
        deepSleepMinutes: 120,
        avgHeartRate: 72,
        avgSpo2: 98,
        avgStress: 35,
        updatedAt: DateTime.now(),
      ));

      await healthRepo.upsertSportRecords([
        HealthSportRecord(
          id: 'sport_test_001',
          sid: 'sid_test_001',
          category: 'running',
          title: '晨跑 5 公里',
          startTime: DateTime.parse('2026-09-15T07:00:00'),
          endTime: DateTime.parse('2026-09-15T07:30:00'),
          durationSeconds: 1800,
          distanceMeters: 5000,
          calories: 300,
          avgPace: 360,
          avgHeartRate: 155,
          createdAt: DateTime.now(),
        )
      ]);

      final content = await vfs.readFile('/health/2026-09-15.json');
      expect(content, contains('9500'));
      expect(content, contains('晨跑 5 公里'));
      expect(content, contains('deep_sleep_min'));
    });

    test('readFile /health/summary.json 返回近期汇总指标', () async {
      final summaryContent = await vfs.readFile('/health/summary.json');
      expect(summaryContent, contains('小米运动健康最近同步汇总'));
      expect(summaryContent, contains('recent_daily_metrics'));
    });
  });
}
