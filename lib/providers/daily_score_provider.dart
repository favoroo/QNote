import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/storage/daily_score_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/daily_score.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';
export 'package:qnote_flutter/providers/selected_date_provider.dart';

final dailyScoreRepositoryProvider = Provider<DailyScoreRepository>((ref) {
  return DailyScoreRepository();
});

final dailyScoreProvider = AsyncNotifierProvider<DailyScoreNotifier, DailyScore?>(() {
  return DailyScoreNotifier();
});

class DailyScoreNotifier extends AsyncNotifier<DailyScore?> {
  DailyScoreRepository get _repository => ref.read(dailyScoreRepositoryProvider);
  // 通过 Provider 注入，遵循 AGENTS.md「Repository 通过 Provider 注入保持单例」约定
  DiaryRepository get _diaryRepository => ref.read(diaryRepositoryProvider);

  @override
  Future<DailyScore?> build() async {
    final date = ref.watch(selectedDateProvider);
    return _repository.getByDate(date);
  }

  Future<void> refresh() async {
    final date = ref.read(selectedDateProvider);
    // 保留旧值：copyWithPrevious 会让 UI 继续显示旧数据，避免 loading 闪烁
    state = const AsyncLoading<DailyScore?>().copyWithPrevious(state);
    state = await AsyncValue.guard(() => _repository.getByDate(date));
  }

  Future<DailyScore> performScore(DateTime date) async {
    final records = await _diaryRepository.getByDateWithSleepByEndTime(date);
    if (records.length < 3) {
      throw Exception('当日信息过少，暂无法评分');
    }

    final repo = ConfigRepository.instance;
    final userProfile = await repo.getUserProfile();
    String? userInfo;
    if (userProfile != null) {
      final Map<String, dynamic> profileMap = {
        'nickname': userProfile.nickname,
        'birthday': userProfile.birthday,
        'height': userProfile.height,
        'gender': userProfile.gender,
        'otherInfo': userProfile.otherInfo,
      };
      if (userProfile.weightHistory.isNotEmpty) {
        final sorted = [...userProfile.weightHistory]..sort((a, b) => b.time.compareTo(a.time));
        profileMap['latestWeight'] = sorted.first.weight;
      }
      userInfo = jsonEncode(profileMap);
    }

    final aiService = ref.read(aiServiceProvider);
    final config = await AiRoleService.instance.getEffectiveConfigForRole('assistant');
    final settings = await AiRoleService.instance.getSettingsForRole('assistant');
    aiService.updateConfig(
      config,
      temperature: settings.temperature,
      maxTokens: settings.maxTokens,
    );

    final score = await aiService.analyzeDailyScore(
      records: records,
      date: date,
      userInfo: userInfo,
    );

    await _repository.insert(score);
    await refresh();
    ref.invalidate(dailyScoreHistoryProvider);
    return score;
  }

  Future<DailyScore> rescore(DateTime date) async {
    final existing = await _repository.getByDate(date);
    if (existing != null) {
      await _repository.delete(existing.id);
    }
    return performScore(date);
  }
}

final dailyScoreHistoryProvider = FutureProvider.family<List<DailyScore>, int>((ref, days) async {
  final repository = ref.watch(dailyScoreRepositoryProvider);
  final end = DateTime.now();
  final start = end.subtract(Duration(days: days));
  final list = await repository.getByDateRange(start, end);
  return list.reversed.toList(); // Return ascending by date for charts
});

/// 热力图数据：近 90 天的评分记录
final dailyScoreHeatmapProvider = FutureProvider<List<DailyScore>>((ref) async {
  final repository = ref.watch(dailyScoreRepositoryProvider);
  final end = DateTime.now();
  final start = end.subtract(const Duration(days: 90));
  return repository.getByDateRange(start, end);
});

final dailyRecordsProvider = FutureProvider<List<DiaryRecord>>((ref) async {
  final date = ref.watch(selectedDateProvider);
  final repo = ref.read(diaryRepositoryProvider);
  return repo.getByDateWithSleepByEndTime(date);
});
