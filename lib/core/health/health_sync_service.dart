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
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';

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
  static const String keyAutoSync = 'health_sync_auto_sync';
  static const String keyDailyStepTarget = 'health_sync_daily_step_target';
  static const int defaultDailyStepTarget = 8000;

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

  /// 是否在应用启动时自动同步（默认开启，已授权用户开箱即用）
  Future<bool> getAutoSync() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyAutoSync) ?? true;
  }

  /// 设置是否在应用启动时自动同步
  Future<void> setAutoSync(bool enable) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyAutoSync, enable);
  }

  /// 获取每日目标步数（默认 8000 步）
  Future<int> getDailyStepTarget() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(keyDailyStepTarget) ?? defaultDailyStepTarget;
  }

  /// 设置每日目标步数
  Future<void> setDailyStepTarget(int target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyDailyStepTarget, target);
  }

  /// 执行单日或多日健康同步
  ///
  /// [onProgress] 回调用于通知 UI 层同步进度：(当前天数序号, 总天数, 状态文本)。
  Future<HealthSyncResult> syncDays({
    int daysBack = 2,
    void Function(int current, int total, String message)? onProgress,
  }) async {
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

      // 1. 同步最近 N 天的单次运动记录（含户外跑、骑行、游泳等），先入库
      onProgress?.call(0, daysBack + 1, '正在拉取运动记录...');
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
          }
        }
      } catch (e) {
        LoggerService.instance.warning('Failed to sync sport records: $e');
      }

      // 2. 同步最近 N 天的每日健康汇总（含步数、睡眠、心率、血氧等），按天生成/更新 23:00 专属聚合卡片
      for (int i = 0; i <= daysBack; i++) {
        final targetDate = now.subtract(Duration(days: i));
        final dayLabel = i == 0 ? '今天' : '$i天前';
        onProgress?.call(i, daysBack + 1, '正在同步 $dayLabel 的健康数据...');

        try {
          final summary = await _apiClient.fetchDaySummary(targetDate);
          await _healthRepo.upsertDailyMetrics(summary);
          syncedDaysCount++;

          if (autoTimeline) {
            final daySports = await _healthRepo.getSportRecordsByDate(summary.date);
            final cardCreatedOrUpdated = await _upsertDailyHealthSummaryTimelineCard(summary, daySports);
            if (cardCreatedOrUpdated) newTimelineCardsCount++;
          }
        } catch (e) {
          LoggerService.instance.warning('Failed to sync day summary for $targetDate: $e');
        }
      }

      // 记录最新同步时间
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyLastSyncTime, now.toIso8601String());

      onProgress?.call(daysBack + 1, daysBack + 1, '同步完成');

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

      // 2. 获取当天的运动记录
      final startOfDay = DateTime(targetDate.year, targetDate.month, targetDate.day, 0, 0, 0);
      final endOfDay = DateTime(targetDate.year, targetDate.month, targetDate.day, 23, 59, 59);
      final sports = await _apiClient.fetchSportRecords(startTime: startOfDay, endTime: endOfDay);
      for (final sport in sports) {
        final exists = await _healthRepo.hasSportRecordBySid(sport.sid);
        if (!exists) {
          await _healthRepo.upsertSportRecords([sport]);
          newSportRecordsCount++;
        }
      }

      if (autoTimeline) {
        final daySports = await _healthRepo.getSportRecordsByDate(summary.date);
        final cardCreatedOrUpdated = await _upsertDailyHealthSummaryTimelineCard(summary, daySports);
        if (cardCreatedOrUpdated) newTimelineCardsCount++;
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

  /// 自动生成或更新 23:00 专属「运动健康」日结卡片（聚合当天步数、睡眠、体征与单次运动，并清理历史分散卡片）
  Future<bool> _upsertDailyHealthSummaryTimelineCard(
    HealthDailyMetrics summary,
    List<HealthSportRecord> sports,
  ) async {
    final date = DateTime.tryParse(summary.date);
    if (date == null) return false;

    // 只有当有步数、睡眠、体征或运动数据时才生成
    final hasData = summary.steps > 0 ||
        summary.sleepDurationMinutes > 0 ||
        sports.isNotEmpty ||
        summary.calories > 0;
    if (!hasData) return false;

    // 固定在当天的 23:00 作为健康日结
    final targetTime = DateTime(date.year, date.month, date.day, 23, 0);

    // 1. 清理该天历史上分散创建的单次运动卡片和睡眠卡片（软删除，避免界面重复散乱）
    final dateRecords = await _diaryRepo.getByDate(targetTime);
    for (final r in dateRecords) {
      final bs = r.bodyState;
      if (bs != null && bs['source'] == 'mi_fitness') {
        final t = bs['type'];
        if (t == 'sport' || t == 'sleep' || bs['mi_fitness_sid'] != null) {
          await _diaryRepo.softDelete(r.id);
        }
      }
    }

    // 2. 查找当天是否已存在 23:00 运动健康综合卡片
    DiaryRecord? existingCard;
    for (final r in dateRecords) {
      final bs = r.bodyState;
      if (bs != null &&
          bs['source'] == 'mi_fitness' &&
          bs['type'] == 'daily_summary' &&
          bs['date'] == summary.date &&
          !r.isDeleted) {
        existingCard = r;
        break;
      }
    }

    // 3. 构建结构化 bodyState 与 Markdown 文本
    final stepTarget = await getDailyStepTarget();
    final distKm = (summary.distanceMeters / 1000).toStringAsFixed(2);
    final calStr = summary.calories.toStringAsFixed(0);
    final sleepHours = summary.sleepDurationMinutes ~/ 60;
    final sleepMins = summary.sleepDurationMinutes % 60;
    final sleepScoreStr = summary.sleepScore != null ? ' (得分: ${summary.sleepScore})' : '';

    final contentLines = <String>[];
    contentLines.add('今日步数: ${summary.steps} 步 (目标 $stepTarget 步) | 消耗: $calStr kcal | 活动: ${summary.activeMinutes} 分钟 | 距离: $distKm km${summary.standingCount > 0 ? ' | 站立: ${summary.standingCount}次' : ''}');

    if (summary.sleepDurationMinutes > 0) {
      final quality = _mapSleepScoreToQuality(summary.sleepScore);
      contentLines.add('昨晚睡眠: $sleepHours小时$sleepMins分 · $quality$sleepScoreStr | 深睡: ${summary.deepSleepMinutes}分 | 浅睡: ${summary.lightSleepMinutes}分 | REM: ${summary.remSleepMinutes}分');
    }

    final vitals = <String>[];
    if (summary.restingHeartRate != null && summary.restingHeartRate! > 0) {
      vitals.add('静息心率: ${summary.restingHeartRate} bpm');
    }
    if (summary.avgSpo2 != null && summary.avgSpo2! > 0) {
      vitals.add('平均血氧: ${summary.avgSpo2}%');
    }
    if (summary.avgStress != null && summary.avgStress! > 0) {
      vitals.add('压力指数: ${summary.avgStress}');
    }
    if (vitals.isNotEmpty) {
      contentLines.add('生理体征: ${vitals.join(' | ')}');
    }

    if (sports.isNotEmpty) {
      contentLines.add('今日运动 (${sports.length}次):');
      for (final s in sports) {
        final sDist = s.distanceMeters > 0 ? ' ${(s.distanceMeters / 1000).toStringAsFixed(2)}km' : '';
        final sDur = '${s.durationSeconds ~/ 60}分钟';
        final sCal = s.calories > 0 ? ', 消耗 ${s.calories.toStringAsFixed(0)}kcal' : '';
        final sHr = s.avgHeartRate != null && s.avgHeartRate! > 0 ? ', 心率 ${s.avgHeartRate}bpm' : '';
        final sPace = s.avgPace != null && s.avgPace! > 0 ? ', 配速 ${_formatPace(s.avgPace!)}' : '';
        contentLines.add('· ${s.title}$sDist ($sDur$sCal$sHr$sPace)');
      }
    }

    final sportsData = sports.map((s) => {
      'sid': s.sid,
      'title': s.title,
      'category': s.category,
      'start_time': s.startTime.toIso8601String(),
      'end_time': s.endTime.toIso8601String(),
      'duration_seconds': s.durationSeconds,
      'distance_meters': s.distanceMeters,
      'calories': s.calories,
      'avg_hr': s.avgHeartRate,
      'avg_pace': s.avgPace != null ? _formatPace(s.avgPace!) : null,
    }).toList();

    final bodyState = {
      'source': 'mi_fitness',
      'type': 'daily_summary',
      'date': summary.date,
      'steps': summary.steps,
      'step_target': stepTarget,
      'distance_meters': summary.distanceMeters,
      'calories': summary.calories,
      'active_minutes': summary.activeMinutes,
      'standing_count': summary.standingCount,
      'sleep_duration_minutes': summary.sleepDurationMinutes,
      'sleep_score': summary.sleepScore,
      'sleep_start_time': summary.sleepStartTime,
      'sleep_end_time': summary.sleepEndTime,
      'deep_sleep_minutes': summary.deepSleepMinutes,
      'light_sleep_minutes': summary.lightSleepMinutes,
      'rem_sleep_minutes': summary.remSleepMinutes,
      'awake_minutes': summary.awakeMinutes,
      'resting_heart_rate': summary.restingHeartRate,
      'avg_spo2': summary.avgSpo2,
      'avg_stress': summary.avgStress,
      'sports': sportsData,
    };

    final record = DiaryRecord(
      id: existingCard?.id ?? const Uuid().v4(),
      title: '运动健康日结 · ${summary.steps} 步',
      time: targetTime,
      startTime: targetTime,
      endTime: targetTime,
      displayTag: '运动健康',
      tags: ['运动健康'],
      tagEntries: [
        TagEntry(
          id: 'health_summary',
          name: '运动健康',
          fields: {
            '步数': summary.steps,
            '消耗': '${calStr}kcal',
            if (summary.standingCount > 0) '站立': '${summary.standingCount}次',
            if (summary.sleepDurationMinutes > 0) '睡眠': '$sleepHours小时$sleepMins分',
            if (sports.isNotEmpty) '运动项': '${sports.length}项',
          },
          startHour: 23,
          startMinute: 0,
          endHour: 23,
          endMinute: 0,
        ),
      ],
      content: contentLines.join('\n'),
      bodyState: bodyState,
      colorMark: '#10B981',
      createdAt: existingCard?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    if (existingCard != null) {
      await _diaryRepo.update(record);
      WorkspaceEventBus.instance.emit(
        '/timeline/${summary.date}.json',
        WorkspaceChangeType.updated,
        record.toMap(),
      );
    } else {
      await _diaryRepo.insert(record);
      WorkspaceEventBus.instance.emit(
        '/timeline/${summary.date}.json',
        WorkspaceChangeType.created,
        record.toMap(),
      );
    }
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
