import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/health/mi_fitness_api_client.dart';
import 'package:qnote_flutter/core/health/mi_fitness_auth_service.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';

final healthSyncServiceProvider = Provider<HealthSyncService>((ref) {
  final apiClient = ref.watch(miFitnessApiClientProvider);
  final healthRepo = ref.watch(healthMetricRepositoryProvider);
  final authService = ref.watch(miFitnessAuthServiceProvider);
  return HealthSyncService(
    apiClient: apiClient,
    healthRepo: healthRepo,
    authService: authService,
    diaryRepo: DiaryRepository(),
  );
});

class HealthSyncResult {
  final bool success;
  final String? errorMessage;
  final int syncedDays;
  final int newSportRecords;
  final int newTimelineCards;

  HealthSyncResult({
    required this.success,
    this.errorMessage,
    this.syncedDays = 0,
    this.newSportRecords = 0,
    this.newTimelineCards = 0,
  });
}

class HealthSyncService {
  final MiFitnessApiClient _apiClient;
  final HealthMetricRepository _healthRepo;
  final MiFitnessAuthService _authService;
  final DiaryRepository _diaryRepo;

  static const String keyAutoCreateTimelineCards = 'health_sync_auto_timeline';
  static const String keyLastSyncTime = 'health_sync_last_time';

  HealthSyncService({
    required MiFitnessApiClient apiClient,
    required HealthMetricRepository healthRepo,
    required MiFitnessAuthService authService,
    required DiaryRepository diaryRepo,
  })  : _apiClient = apiClient,
        _healthRepo = healthRepo,
        _authService = authService,
        _diaryRepo = diaryRepo;

  /// 检查是否配置并授权成功
  Future<bool> isAuthorized() async {
    final creds = await _authService.loadCredentials();
    return creds != null && creds.ssecurity.isNotEmpty;
  }

  /// 获取上次同步时间
  Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(keyLastSyncTime);
    if (str == null || str.isEmpty) return null;
    return DateTime.tryParse(str);
  }

  /// 是否自动沉淀为时间线卡片
  Future<bool> getAutoCreateTimelineCards() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyAutoCreateTimelineCards) ?? true;
  }

  /// 设置是否自动沉淀为时间线卡片
  Future<void> setAutoCreateTimelineCards(bool enable) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyAutoCreateTimelineCards, enable);
  }

  /// 执行单日或多日健康同步
  Future<HealthSyncResult> syncDays({int daysBack = 2}) async {
    final authed = await isAuthorized();
    if (!authed) {
      return HealthSyncResult(
        success: false,
        errorMessage: '未绑定小米运动健康账号，请先授权登录',
      );
    }

    try {
      final now = DateTime.now();
      int syncedDaysCount = 0;
      int newSportRecordsCount = 0;
      int newTimelineCardsCount = 0;

      final autoTimeline = await getAutoCreateTimelineCards();

      // 1. 同步最近 N 天的每日健康汇总（含步数、睡眠、心率、血氧等）
      for (int i = 0; i <= daysBack; i++) {
        final targetDate = now.subtract(Duration(days: i));
        try {
          final summary = await _apiClient.fetchDaySummary(targetDate);
          await _healthRepo.upsertDailyMetrics(summary);
          syncedDaysCount++;

          // 如果需要且有睡眠数据，自动沉淀睡眠卡片
          if (autoTimeline && summary.sleepDurationMinutes > 0) {
            final cardCreated = await _createSleepTimelineCardIfNeeded(summary);
            if (cardCreated) newTimelineCardsCount++;
          }
        } catch (e) {
          LoggerService.instance.warning('Failed to sync day summary for $targetDate: $e');
        }
      }

      // 2. 同步时间段内的单次运动记录（含户外跑、骑行、游泳等）
      final startTime = now.subtract(Duration(days: daysBack + 1));
      try {
        final sports = await _apiClient.fetchSportRecords(
          startTime: startTime,
          endTime: now,
        );

        for (final sport in sports) {
          final exists = await _healthRepo.hasSportRecordBySid(sport.sid);
          if (!exists) {
            await _healthRepo.upsertSportRecords([sport]);
            newSportRecordsCount++;

            if (autoTimeline) {
              final cardCreated = await _createSportTimelineCardIfNeeded(sport);
              if (cardCreated) newTimelineCardsCount++;
            }
          }
        }
      } catch (e) {
        LoggerService.instance.warning('Failed to sync sport records: $e');
      }

      // 记录最新同步时间
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyLastSyncTime, now.toIso8601String());

      return HealthSyncResult(
        success: true,
        syncedDays: syncedDaysCount,
        newSportRecords: newSportRecordsCount,
        newTimelineCards: newTimelineCardsCount,
      );
    } catch (e) {
      LoggerService.instance.error('Health sync failed: $e');
      return HealthSyncResult(
        success: false,
        errorMessage: '同步失败: $e',
      );
    }
  }

  /// 同步指定某一天的健康与运动数据（支持任意历史日期按需拉取）
  Future<HealthSyncResult> syncDate(DateTime targetDate) async {
    final authed = await isAuthorized();
    if (!authed) {
      return HealthSyncResult(
        success: false,
        errorMessage: '未绑定小米运动健康账号，请先授权登录',
      );
    }

    try {
      final autoTimeline = await getAutoCreateTimelineCards();
      int newTimelineCardsCount = 0;
      int newSportRecordsCount = 0;

      // 1. 获取当天的指标汇总
      final summary = await _apiClient.fetchDaySummary(targetDate);
      await _healthRepo.upsertDailyMetrics(summary);

      if (autoTimeline && summary.sleepDurationMinutes > 0) {
        final cardCreated = await _createSleepTimelineCardIfNeeded(summary);
        if (cardCreated) newTimelineCardsCount++;
      }

      // 2. 获取当天的运动记录
      final startOfDay = DateTime(targetDate.year, targetDate.month, targetDate.day, 0, 0, 0);
      final endOfDay = DateTime(targetDate.year, targetDate.month, targetDate.day, 23, 59, 59);
      final sports = await _apiClient.fetchSportRecords(startTime: startOfDay, endTime: endOfDay);
      for (final sport in sports) {
        final exists = await _healthRepo.hasSportRecordBySid(sport.sid);
        if (!exists) {
          await _healthRepo.upsertSportRecords([sport]);
          newSportRecordsCount++;
          if (autoTimeline) {
            final cardCreated = await _createSportTimelineCardIfNeeded(sport);
            if (cardCreated) newTimelineCardsCount++;
          }
        }
      }

      return HealthSyncResult(
        success: true,
        syncedDays: 1,
        newSportRecords: newSportRecordsCount,
        newTimelineCards: newTimelineCardsCount,
      );
    } catch (e) {
      LoggerService.instance.error('Health sync single date failed: $e');
      return HealthSyncResult(
        success: false,
        errorMessage: '同步失败: $e',
      );
    }
  }

  /// 自动生成单次运动的时间线卡片（防重）
  Future<bool> _createSportTimelineCardIfNeeded(HealthSportRecord sport) async {
    final dateRecords = await _diaryRepo.getByDate(sport.startTime);
    final isDuplicate = dateRecords.any((r) {
      if (r.bodyState != null && r.bodyState!['mi_fitness_sid'] == sport.sid) {
        return true;
      }
      return false;
    });

    if (isDuplicate) return false;

    final distKm = (sport.distanceMeters / 1000).toStringAsFixed(2);
    final durMin = sport.durationSeconds ~/ 60;
    final calStr = sport.calories.toStringAsFixed(0);

    final title = '${sport.title}${sport.distanceMeters > 0 ? ' $distKm km' : ''}';
    final contentParts = <String>[
      '运动时长: $durMin 分钟',
      if (sport.distanceMeters > 0) '运动距离: $distKm km',
      if (sport.calories > 0) '活动消耗: $calStr kcal',
      if (sport.avgHeartRate != null && sport.avgHeartRate! > 0) '平均心率: ${sport.avgHeartRate} bpm',
      if (sport.avgPace != null && sport.avgPace! > 0) '平均配速: ${_formatPace(sport.avgPace!)}',
    ];

    final record = DiaryRecord(
      id: const Uuid().v4(),
      title: title,
      time: sport.startTime,
      startTime: sport.startTime,
      endTime: sport.endTime,
      displayTag: '活动',
      tags: ['活动', '运动'],
      tagEntries: [
        TagEntry(
          id: 'activity',
          name: '活动',
          fields: {
            'type': '运动',
            'duration': (sport.durationSeconds / 3600).toStringAsFixed(2),
            'sub_type': sport.title,
            if (sport.distanceMeters > 0) 'distance_km': distKm,
            if (sport.calories > 0) 'calories': calStr,
            if (sport.avgHeartRate != null && sport.avgHeartRate! > 0) 'avg_hr': sport.avgHeartRate,
            if (sport.avgPace != null && sport.avgPace! > 0) 'avg_pace': _formatPace(sport.avgPace!),
          },
          startHour: sport.startTime.hour,
          startMinute: sport.startTime.minute,
          endHour: sport.endTime.hour,
          endMinute: sport.endTime.minute,
        ),
      ],
      content: contentParts.join(' | '),
      bodyState: {
        'source': 'mi_fitness',
        'mi_fitness_sid': sport.sid,
        'category': sport.category,
      },
      colorMark: '#4CAF50',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _diaryRepo.insert(record);
    return true;
  }

  /// 自动生成睡眠的时间线卡片（防重）
  Future<bool> _createSleepTimelineCardIfNeeded(HealthDailyMetrics summary) async {
    final date = DateTime.tryParse(summary.date);
    if (date == null) return false;

    final dateRecords = await _diaryRepo.getByDate(date);
    final isDuplicate = dateRecords.any((r) {
      if (r.bodyState != null &&
          r.bodyState!['source'] == 'mi_fitness' &&
          r.bodyState!['type'] == 'sleep' &&
          r.bodyState!['date'] == summary.date) {
        return true;
      }
      return false;
    });

    if (isDuplicate) return false;

    final hours = summary.sleepDurationMinutes ~/ 60;
    final mins = summary.sleepDurationMinutes % 60;
    final scoreStr = summary.sleepScore != null ? ' (得分: ${summary.sleepScore})' : '';

    final sleepQuality = _mapSleepScoreToQuality(summary.sleepScore);

    final contentParts = <String>[
      '总睡眠: $hours小时$mins分$scoreStr',
      if (summary.deepSleepMinutes > 0) '深睡: ${summary.deepSleepMinutes}分',
      if (summary.lightSleepMinutes > 0) '浅睡: ${summary.lightSleepMinutes}分',
      if (summary.remSleepMinutes > 0) '快速眼动: ${summary.remSleepMinutes}分',
      if (summary.awakeMinutes > 0) '清醒: ${summary.awakeMinutes}分',
    ];

    // 默认以早晨 08:00 或醒来时间作为记录时间
    DateTime recordTime = DateTime(date.year, date.month, date.day, 8, 0);
    if (summary.sleepEndTime != null) {
      final parts = summary.sleepEndTime!.split(':');
      if (parts.length >= 2) {
        final h = int.tryParse(parts[0]) ?? 8;
        final m = int.tryParse(parts[1]) ?? 0;
        recordTime = DateTime(date.year, date.month, date.day, h, m);
      }
    }

    final record = DiaryRecord(
      id: const Uuid().v4(),
      title: '作息睡眠 $hours小时$mins分$scoreStr',
      time: recordTime,
      displayTag: '睡眠',
      tags: ['睡眠'],
      tagEntries: [
        TagEntry(
          id: 'sleep',
          name: '睡眠',
          fields: {
            'fallAsleepTime': summary.sleepStartTime ?? '',
            'duration': (summary.sleepDurationMinutes / 60).toStringAsFixed(1),
            'quality': sleepQuality,
          },
        ),
      ],
      content: contentParts.join(' | '),
      bodyState: {
        'source': 'mi_fitness',
        'type': 'sleep',
        'date': summary.date,
      },
      colorMark: '#9C27B0',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _diaryRepo.insert(record);
    return true;
  }

  String _mapSleepScoreToQuality(int? score) {
    if (score == null) return '良好';
    if (score >= 90) return '极好';
    if (score >= 75) return '良好';
    if (score >= 60) return '一般';
    return '较差';
  }

  String _formatPace(double paceSeconds) {
    final min = paceSeconds ~/ 60;
    final sec = (paceSeconds % 60).toInt();
    return '$min\'${sec.toString().padLeft(2, '0')}\'\'';
  }
}
