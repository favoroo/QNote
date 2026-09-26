import 'package:uuid/uuid.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/daily_score_repository.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/models/daily_score.dart';

/// 单日评分落库结果。
class ScoreUpsertResult {
  const ScoreUpsertResult({required this.saved, required this.created});

  final DailyScore saved;
  final bool created;

  String get status => created ? 'created' : 'updated';
}

/// 范围调整结果；[outcomes] 只含实际发生变化的天。
class ScoreAdjustRangeResult {
  const ScoreAdjustRangeResult({
    required this.outcomes,
    required this.scoredDays,
    required this.missingDays,
    required this.dryRun,
  });

  final List<ScoreAdjustOutcome> outcomes;

  /// 区间内已有评分的天数
  final int scoredDays;

  /// 区间内没有评分、因此被跳过的天数
  final int missingDays;
  final bool dryRun;

  int get applied => outcomes.length;
  int get clamped => outcomes.where((o) => o.clamped).length;

  String get preview => describeScoreAdjustPreview(outcomes, missingDays: missingDays);
}

/// 每日生活评分的写入口，供小Q 的 VFS 端点与统计页批量抽屉共用。
///
/// 集中在一处是为了锁死两条语义：payload 未出现的字段保持原值（而不是被总分或
/// 默认值覆盖）、以及调整历史区间时绝不凭空造出评分。
class DailyScoreService {
  static final DailyScoreService instance = DailyScoreService._();
  DailyScoreService._();

  final DailyScoreRepository _repository = DailyScoreRepository();

  /// 单次范围调整的最大跨度，与小Q 可调目录和热力图口径对齐
  static const int maxAdjustRangeDays = 92;

  /// AI 首次打分漏字段时的保守基线
  static const int kBaselineScore = 60;

  /// 按字段写入单日评分：[totalScore] 为 null 时不改总分，
  /// [dimensionScores] 只覆盖其中出现的键，其余维度保持库里的原值。
  Future<ScoreUpsertResult> upsertFromPayload({
    required DateTime date,
    int? totalScore,
    Map<String, int>? dimensionScores,
    String? summary,
    String? suggestions,
    int? recordCount,
  }) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final existing = await _repository.getByDate(normalizedDate);
    final trimmedSummary = summary?.trim() ?? '';
    final trimmedSuggestions = suggestions?.trim() ?? '';

    DailyScore saved;
    if (existing == null) {
      final total = clampScore(totalScore ?? kBaselineScore);
      // 新建时才补齐五维：统计页有五条维度条，AI 漏写维度时留空会显示成缺项
      final dims = _clampValues(dimensionScores);
      for (final field in ScoreField.values) {
        if (field.isDimension) {
          dims.putIfAbsent(field.storageKey, () => total);
        }
      }
      final now = DateTime.now();
      saved = await _repository.upsertByDate(
        DailyScore(
          id: const Uuid().v4(),
          date: normalizedDate,
          totalScore: total,
          dimensionScores: dims,
          summary: trimmedSummary,
          suggestions: trimmedSuggestions,
          recordCount: recordCount ?? 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      _emitDay(saved, created: true);
      return ScoreUpsertResult(saved: saved, created: true);
    }

    saved = await _repository.upsertByDate(
      existing.copyWith(
        totalScore: totalScore == null ? existing.totalScore : clampScore(totalScore),
        dimensionScores: mergeDimensionScores(
          existing.dimensionScores,
          _clampValues(dimensionScores),
        ),
        summary: trimmedSummary.isEmpty ? existing.summary : trimmedSummary,
        suggestions: trimmedSuggestions.isEmpty ? existing.suggestions : trimmedSuggestions,
        recordCount: recordCount ?? existing.recordCount,
      ),
    );
    _emitDay(saved, created: false);
    return ScoreUpsertResult(saved: saved, created: false);
  }

  /// 对一段日期区间应用同一份调整规则。
  ///
  /// [dryRun] 为 true 时只算不写，供小Q 与统计页先给用户看预览。
  /// 区间内没有评分的天一律跳过：批量调整若按基线分补造记录，热力图与趋势里
  /// 会混入用户无法分辨的假评分。
  Future<ScoreAdjustRangeResult> adjustRange({
    required DateTime from,
    required DateTime to,
    required ScoreAdjustSpec spec,
    bool dryRun = false,
  }) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day);
    if (end.isBefore(start)) {
      throw Exception('结束日期不能早于开始日期');
    }
    final spanDays = end.difference(start).inDays + 1;
    if (spanDays > maxAdjustRangeDays) {
      throw Exception('单次最多调整 $maxAdjustRangeDays 天，当前跨度 $spanDays 天，请缩小日期范围分批处理');
    }

    final scored = await _repository.getLatestByDateRange(start, end);
    final outcomes = scored
        .map((score) => applyScoreAdjust(score, spec))
        .where((outcome) => outcome.changed)
        .toList();
    final missingDays = spanDays - scored.length;

    if (dryRun || outcomes.isEmpty) {
      return ScoreAdjustRangeResult(
        outcomes: outcomes,
        scoredDays: scored.length,
        missingDays: missingDays,
        dryRun: dryRun,
      );
    }

    await _repository.upsertBatch(outcomes.map((outcome) => outcome.after).toList());
    // 整批只广播一次：逐天 emit 会让监听方对同一批改动重复重查几十次
    WorkspaceEventBus.instance.emit(
      '/stats/daily_scores.json',
      WorkspaceChangeType.updated,
      outcomes.length,
    );
    return ScoreAdjustRangeResult(
      outcomes: outcomes,
      scoredDays: scored.length,
      missingDays: missingDays,
      dryRun: false,
    );
  }

  void _emitDay(DailyScore saved, {required bool created}) {
    final dateStr = saved.date.toIso8601String().split('T').first;
    WorkspaceEventBus.instance.emit(
      '/stats/scores/$dateStr.json',
      created ? WorkspaceChangeType.created : WorkspaceChangeType.updated,
      saved,
    );
    WorkspaceEventBus.instance.emit(
      '/stats/daily_scores.json',
      WorkspaceChangeType.updated,
      saved,
    );
  }

  Map<String, int> _clampValues(Map<String, int>? incoming) {
    if (incoming == null) return <String, int>{};
    return incoming.map((key, value) => MapEntry(key, clampScore(value)));
  }
}
