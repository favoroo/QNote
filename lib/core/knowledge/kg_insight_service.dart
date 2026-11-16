import 'package:qnote_flutter/core/knowledge/kg_resolver.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_insight_math.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 关联发现服务：从「按日出现的实体/状态」里挖掘可解释的相关性。
///
/// 只统计 `kg_mentions`（置信度 ≥0.7），不拿 LLM 语义边算数字；
/// 输出带支持天数、概率、提升度和证据日期，强调「相关不是因果」。
class KnowledgeGraphInsightService {
  static final KnowledgeGraphInsightService instance = KnowledgeGraphInsightService._internal();
  KnowledgeGraphInsightService._internal();

  final KnowledgeGraphRepository _repo = KnowledgeGraphRepository();

  /// 同一指标派生的状态对不参与统计，否则「步数少」和「没运动」这种
  /// 由同一个健康日算出来的组合会被当成规律。
  static const Map<String, String> _stateGroups = {
    'low_steps': 'activity_metric',
    'no_exercise': 'activity_metric',
    'sleep_short': 'sleep_metric',
    'late_sleep': 'sleep_metric',
    'low_mood': 'mood_metric',
    'high_mood': 'mood_metric',
    'high_screen': 'screen_metric',
  };

  static const int _minDays = 21;
  static const int _windowDays = 180;

  Future<List<KgInsight>> rebuild({int limit = 20}) async {
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: _windowDays));
    final mentions = await _repo.getMentionsInRange(from, now, limit: 100000);

    final byDate = <String, Set<String>>{};
    final mentionByDateNode = <String, KgMention>{};
    for (final mention in mentions) {
      if (mention.confidenceScore < 0.7) continue;
      final date = mention.occurredDate ?? (mention.occurredAt == null ? null : kgDateKey(mention.occurredAt!));
      if (date == null || date.isEmpty) continue;
      byDate.putIfAbsent(date, () => <String>{}).add(mention.nodeId);
      mentionByDateNode.putIfAbsent('$date|${mention.nodeId}', () => mention);
    }

    if (byDate.length < _minDays) {
      await _repo.replaceInsights(const []);
      await _repo.setMeta('last_insight_at', now.toIso8601String());
      return const [];
    }

    final nodes = await _repo.getNodesByIds(byDate.values.expand((ids) => ids));
    final nodeById = {for (final node in nodes) node.id: node};

    final excludedPairs = <String>{};
    final grouped = <String, List<String>>{};
    for (final node in nodes) {
      final group = _stateGroups[node.type];
      if (group != null) grouped.putIfAbsent(group, () => []).add(node.id);
    }
    for (final ids in grouped.values) {
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          final a = ids[i];
          final b = ids[j];
          final sorted = a.compareTo(b) <= 0 ? [a, b] : [b, a];
          excludedPairs.add('association|${sorted[0]}|${sorted[1]}');
          excludedPairs.add('lagged|$a|$b');
          excludedPairs.add('lagged|$b|$a');
        }
      }
    }

    final candidates = KgInsightMath.mine(featuresByDate: byDate, excludedPairs: excludedPairs);

    final insights = <KgInsight>[];
    final created = DateTime.now();
    for (final candidate in candidates) {
      final a = nodeById[candidate.aId];
      final b = nodeById[candidate.bId];
      if (a == null || b == null) continue;
      final evidence = _buildEvidence(candidate, a, b, mentionByDateNode);
      final pct = (candidate.confidence * 100).round();
      final basePct = (candidate.baseline * 100).round();
      final lagged = candidate.kind == 'lagged';
      final title = lagged ? '「${a.name}」之后更容易出现「${b.name}」' : '「${a.name}」常和「${b.name}」一起出现';
      final body = lagged
          ? '在有记录的 ${candidate.totalDays} 个相邻日里，出现「${a.name}」的第二天，'
                '有 ${candidate.support}/${candidate.aSupport} 天出现「${b.name}」'
                '（$pct%），平时是 $basePct%。'
          : '在有记录的 ${candidate.totalDays} 天里，有「${a.name}」的 ${candidate.aSupport} 天中，'
                '有 ${candidate.support} 天也出现「${b.name}」（$pct%），'
                '高于平时的 $basePct%。';

      insights.add(
        KgInsight(
          id: KgIds.insight(candidate.kind, a.id, b.id),
          kind: lagged ? KgInsightKind.lagged : KgInsightKind.association,
          title: title,
          body: '$body\n这是相关性，不是因果；可以结合证据日期回看原始记录。',
          score: candidate.score,
          support: candidate.support,
          confidence: candidate.confidence,
          lift: candidate.lift,
          nodeIds: [a.id, b.id],
          evidence: evidence,
          periodStart: DateTime.tryParse(byDate.keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b)),
          periodEnd: DateTime.tryParse(byDate.keys.reduce((a, b) => a.compareTo(b) >= 0 ? a : b)),
          status: 'new',
          createdAt: created,
          updatedAt: created,
        ),
      );
    }

    insights.sort((a, b) => b.score.compareTo(a.score));
    final ranked = insights.take(limit).toList();
    await _repo.replaceInsights(ranked);
    await _repo.setMeta('last_insight_at', now.toIso8601String());
    // 返回数据库里真正可见的 new 条目：已被用户忽略的不会被 replaceInsights 复活
    final visible = await _repo.getInsights(limit: limit, status: 'new');
    LoggerService.instance.logDatabase('关联发现重算完成：${byDate.length} 天，${candidates.length} 个候选，可见 ${visible.length} 条');
    return visible;
  }

  Future<List<KgInsight>> top({int limit = 3}) {
    return _repo.getInsights(limit: limit, status: 'new');
  }

  Future<void> dismiss(String id) {
    return _repo.updateInsightStatus(id, 'dismissed');
  }

  List<KgEvidence> _buildEvidence(
    KgAssociationCandidate candidate,
    KgNode a,
    KgNode b,
    Map<String, KgMention> mentionByDateNode,
  ) {
    final result = <KgEvidence>[];
    final seen = <String>{};
    for (final date in candidate.evidenceDates) {
      final aMention = mentionByDateNode['$date|${a.id}'];
      if (aMention != null) {
        final key = '${aMention.sourceType}|${aMention.sourceId}|${aMention.path}';
        if (seen.add(key)) {
          result.add(
            KgEvidence(
              sourceType: aMention.sourceType,
              sourceId: aMention.sourceId,
              path: aMention.path,
              snippet: aMention.snippet,
              occurredDate: date,
            ),
          );
        }
      }

      final bDate = candidate.kind == 'lagged' ? _nextDate(date) : date;
      if (bDate == null) continue;
      final bMention = mentionByDateNode['$bDate|${b.id}'];
      if (bMention != null) {
        final key = '${bMention.sourceType}|${bMention.sourceId}|${bMention.path}';
        if (seen.add(key)) {
          result.add(
            KgEvidence(
              sourceType: bMention.sourceType,
              sourceId: bMention.sourceId,
              path: bMention.path,
              snippet: bMention.snippet,
              occurredDate: bDate,
            ),
          );
        }
      }
      if (result.length >= 8) break;
    }
    return result;
  }

  String? _nextDate(String date) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return null;
    final next = parsed.add(const Duration(days: 1));
    return kgDateKey(next);
  }
}
