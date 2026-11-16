import 'dart:math' as math;

/// 一条关联候选：同一天共同出现，或 A 之后第二天出现 B。
class KgAssociationCandidate {
  final String aId;
  final String bId;

  /// `association`（同日）或 `lagged`（次日）
  final String kind;
  final int support;
  final int aSupport;
  final int bSupport;
  final int totalDays;
  final double confidence;
  final double baseline;
  final double lift;
  final double diff;
  final double zScore;
  final List<String> evidenceDates;
  final double score;

  const KgAssociationCandidate({
    required this.aId,
    required this.bId,
    required this.kind,
    required this.support,
    required this.aSupport,
    required this.bSupport,
    required this.totalDays,
    required this.confidence,
    required this.baseline,
    required this.lift,
    required this.diff,
    required this.zScore,
    required this.evidenceDates,
    required this.score,
  });
}

/// 关联发现统计：纯函数，不依赖数据库与 Flutter，便于单测。
///
/// 输入是「日期 → 当天出现的节点 id 集合」。统计的是**相关性**而非因果：
/// 支持度、提升度、概率差、两比例 z 检验四个门槛同时满足才输出，
/// 避免个人数据量小的时候把偶然共现包装成规律。
abstract final class KgInsightMath {
  static List<KgAssociationCandidate> mine({
    required Map<String, Set<String>> featuresByDate,
    int minSupport = 4,
    int minASupport = 4,
    int minBSupport = 4,
    int minTotalDays = 21,
    double minLift = 1.5,
    double minDiff = 0.15,
    double minZ = 1.64,
    Set<String> excludedPairs = const {},
    int maxCandidates = 40,
  }) {
    final dates = featuresByDate.keys.where((d) => d.isNotEmpty).toList()..sort();
    final totalDays = dates.length;
    if (totalDays < minTotalDays) return const [];

    final candidates = <String, KgAssociationCandidate>{};

    void consider({
      required String aId,
      required String bId,
      required String kind,
      required int support,
      required int aSupport,
      required int bSupport,
      required int total,
      required List<String> evidenceDates,
    }) {
      if (aId == bId || support <= 0) return;
      if (aSupport < minASupport || bSupport < minBSupport || support < minSupport) return;
      final pairKey = kind == 'lagged'
          ? '$kind|$aId|$bId'
          : '$kind|${aId.compareTo(bId) <= 0 ? aId : bId}|${aId.compareTo(bId) <= 0 ? bId : aId}';
      if (excludedPairs.contains(pairKey)) return;

      final n1 = aSupport;
      final x1 = support;
      final n2 = total - aSupport;
      final x2 = bSupport - support;
      if (n1 <= 0 || n2 <= 0 || x2 < 0) return;

      final p1 = x1 / n1;
      final p2 = x2 / n2;
      final baseline = bSupport / total;
      if (baseline <= 0) return;
      final pooled = bSupport / total;
      final se = math.sqrt(pooled * (1 - pooled) * (1 / n1 + 1 / n2));
      if (se <= 0) return;
      final z = (p1 - p2) / se;
      final diff = p1 - p2;
      final lift = p1 / baseline;
      if (z < minZ || diff < minDiff || lift < minLift) return;

      final score = z * math.log(1 + support);
      final candidate = KgAssociationCandidate(
        aId: aId,
        bId: bId,
        kind: kind,
        support: support,
        aSupport: aSupport,
        bSupport: bSupport,
        totalDays: total,
        confidence: p1,
        baseline: baseline,
        lift: lift,
        diff: diff,
        zScore: z,
        evidenceDates: evidenceDates.take(6).toList(),
        score: score,
      );
      final existing = candidates[pairKey];
      if (existing == null || candidate.score > existing.score) {
        candidates[pairKey] = candidate;
      }
    }

    // 1. 同日关联
    final nodeDates = <String, Set<String>>{};
    for (final entry in featuresByDate.entries) {
      for (final nodeId in entry.value) {
        nodeDates.putIfAbsent(nodeId, () => <String>{}).add(entry.key);
      }
    }
    // 出现率 >70% 的泛化节点不参与统计，避免「每天都有」压过真正规律
    final eligible =
        nodeDates.entries
            .where((e) => e.value.length >= minASupport && e.value.length <= totalDays * 0.7)
            .map((e) => e.key)
            .toList()
          ..sort();

    for (var i = 0; i < eligible.length; i++) {
      final aId = eligible[i];
      final datesA = nodeDates[aId]!;
      for (var j = i + 1; j < eligible.length; j++) {
        final bId = eligible[j];
        final datesB = nodeDates[bId]!;
        if (datesA.length < minASupport || datesB.length < minBSupport) continue;
        final common = datesA.intersection(datesB);
        if (common.length < minSupport) continue;
        final evidence = common.toList()..sort((a, b) => b.compareTo(a));
        consider(
          aId: aId,
          bId: bId,
          kind: 'association',
          support: common.length,
          aSupport: datesA.length,
          bSupport: datesB.length,
          total: totalDays,
          evidenceDates: evidence,
        );
      }
    }

    // 2. 次日滞后：A 在 d 天，B 在 d+1 天
    // 只枚举出现率在合理区间的节点，控制 O(天数 × 节点对) 的规模
    final eligibleSet = eligible.toSet();
    final transitionCount = math.max(0, totalDays - 1);
    if (transitionCount >= minTotalDays) {
      final laggedCounts = <String, Map<String, int>>{};
      final aOccurrences = <String, int>{};
      final bOccurrences = <String, int>{};
      final evidenceByPair = <String, List<String>>{};

      for (var i = 0; i + 1 < dates.length; i++) {
        final date = dates[i];
        final nextDate = dates[i + 1];
        // 只统计真实相邻日；中间断档两天以上不当作「第二天」
        final current = DateTime.tryParse(date);
        final next = DateTime.tryParse(nextDate);
        if (current == null || next == null || next.difference(current).inDays != 1) continue;

        final currentNodes = featuresByDate[date] ?? const {};
        final nextNodes = featuresByDate[nextDate] ?? const {};
        final aNodes = currentNodes.where(eligibleSet.contains).toList();
        final bNodes = nextNodes.where(eligibleSet.contains).toList();
        for (final aId in aNodes) {
          aOccurrences[aId] = (aOccurrences[aId] ?? 0) + 1;
        }
        for (final bId in bNodes) {
          bOccurrences[bId] = (bOccurrences[bId] ?? 0) + 1;
        }
        for (final aId in aNodes) {
          final map = laggedCounts.putIfAbsent(aId, () => <String, int>{});
          for (final bId in bNodes) {
            map[bId] = (map[bId] ?? 0) + 1;
            evidenceByPair.putIfAbsent('$aId|$bId', () => <String>[]).add(date);
          }
        }
      }

      for (final entry in laggedCounts.entries) {
        final aId = entry.key;
        for (final pair in entry.value.entries) {
          final bId = pair.key;
          consider(
            aId: aId,
            bId: bId,
            kind: 'lagged',
            support: pair.value,
            aSupport: aOccurrences[aId] ?? 0,
            bSupport: bOccurrences[bId] ?? 0,
            total: transitionCount,
            evidenceDates: (evidenceByPair['$aId|$bId'] ?? const []).reversed.toList(),
          );
        }
      }
    }

    final list = candidates.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return b.support.compareTo(a.support);
      });
    return list.take(maxCandidates).toList();
  }

  /// 两比例 z 检验（供单测/调试复用）
  static double twoProportionZ({required int x1, required int n1, required int x2, required int n2}) {
    if (n1 <= 0 || n2 <= 0) return 0;
    final p1 = x1 / n1;
    final p2 = x2 / n2;
    final pooled = (x1 + x2) / (n1 + n2);
    final se = math.sqrt(pooled * (1 - pooled) * (1 / n1 + 1 / n2));
    if (se <= 0) return 0;
    return (p1 - p2) / se;
  }
}
