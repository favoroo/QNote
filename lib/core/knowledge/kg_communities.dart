import 'package:qnote_flutter/core/knowledge/kg_resolver.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_graph_algorithms.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 主题社区服务：只聚类实体/状态节点，源记录与日期节点不参与。
///
/// 社区标签先用「加权度最高的 3 个实体名」拼一个可读主题，不额外调用 LLM；
/// 这样主题完全来自用户数据，成本为零、结果可解释。
class KnowledgeGraphCommunityService {
  static final KnowledgeGraphCommunityService instance = KnowledgeGraphCommunityService._internal();
  KnowledgeGraphCommunityService._internal();

  final KnowledgeGraphRepository _repo = KnowledgeGraphRepository();

  Future<List<Map<String, dynamic>>> rebuild() async {
    final allNodes = await _repo.getAllNodes(limit: 10000);
    final semanticNodes = allNodes
        .where((node) => node.kind == KgNodeKind.entity || node.kind == KgNodeKind.state)
        .toList();
    if (semanticNodes.isEmpty) {
      // 空图也要清掉可能残留的聚合边，避免恢复/清空后引用不存在的节点
      await _repo.replaceCoOccurrenceEdges(const []);
      await _repo.setMeta('last_community_at', DateTime.now().toIso8601String());
      return const [];
    }

    // 共现边是聚合结果，先按最新 mentions 全量重建，再聚类
    await _rebuildCoOccurrenceEdges();

    final edges = await _repo.getEdgesAmongKinds(limit: 30000);
    final weightedEdges = [
      for (final edge in edges)
        KgWeightedEdge(
          source: edge.sourceId,
          target: edge.targetId,
          // 权重同时考虑共现次数与置信度：弱关系不应把主题拉偏
          weight: edge.weight * edge.confidenceScore.clamp(0.1, 1.0),
        ),
    ];
    final labels = detectCommunities(nodeIds: semanticNodes.map((node) => node.id), edges: weightedEdges);

    final groups = <int, List<String>>{};
    for (final entry in labels.entries) {
      groups.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    // 单节点社区对用户没有主题意义，置空；其余按规模降序重编号
    final meaningful = groups.values.where((ids) => ids.length >= 2).toList()
      ..sort((a, b) {
        final bySize = b.length.compareTo(a.length);
        if (bySize != 0) return bySize;
        final aKey = a.toList()..sort();
        final bKey = b.toList()..sort();
        return aKey.first.compareTo(bKey.first);
      });

    final updates = <String, int?>{for (final node in semanticNodes) node.id: null};
    final communityByNode = <String, int>{};
    for (var i = 0; i < meaningful.length; i++) {
      for (final nodeId in meaningful[i]) {
        updates[nodeId] = i;
        communityByNode[nodeId] = i;
      }
    }
    await _repo.updateCommunityIds(updates);
    await _repo.setMeta('last_community_at', DateTime.now().toIso8601String());
    LoggerService.instance.logDatabase('知识图谱社区重算完成：${semanticNodes.length} 个节点，${meaningful.length} 个主题');
    return _topicsFromNodes(semanticNodes, communityByNode);
  }

  /// 读取当前主题：不重算，只按已有的 community_id 分组
  Future<List<Map<String, dynamic>>> topics({int limit = 20}) async {
    final nodes = await _repo.getAllNodes(limit: 10000);
    final semanticNodes = nodes
        .where((node) => (node.kind == KgNodeKind.entity || node.kind == KgNodeKind.state) && node.communityId != null)
        .toList();
    final communityByNode = <String, int>{for (final node in semanticNodes) node.id: node.communityId!};
    return _topicsFromNodes(semanticNodes, communityByNode).take(limit).toList();
  }

  /// 按最新提及重建「共同出现」边。
  ///
  /// 每条源记录内最多取 8 个高置信节点两两组合，避免长笔记产生几十条噪音边；
  /// 同一对节点跨多条记录重复出现时累加权重，这样主题聚类更偏向稳定共现。
  Future<void> _rebuildCoOccurrenceEdges() async {
    final now = DateTime.now();
    final mentions = await _repo.getMentionsInRange(now.subtract(const Duration(days: 365)), now, limit: 100000);

    final bySource = <String, _SourceMentions>{};
    for (final mention in mentions) {
      if (mention.confidenceScore < 0.7 || mention.nodeId.isEmpty) continue;
      final key = '${mention.sourceType}|${mention.sourceId}';
      final group = bySource.putIfAbsent(
        key,
        () => _SourceMentions(sourceType: mention.sourceType, sourceId: mention.sourceId),
      );
      group.mentions.putIfAbsent(mention.nodeId, () => mention);
    }

    final pairs = <String, _PairAgg>{};
    for (final group in bySource.values) {
      final ids = group.mentions.keys.toList()..sort();
      final top = ids.take(8).toList();
      for (var i = 0; i < top.length; i++) {
        for (var j = i + 1; j < top.length; j++) {
          final aId = top[i];
          final bId = top[j];
          final key = '$aId|$bId';
          final agg = pairs.putIfAbsent(key, () => _PairAgg(aId: aId, bId: bId));
          agg.weight += 1;
          if (agg.evidence.length < 3) {
            final aMention = group.mentions[aId]!;
            final bMention = group.mentions[bId]!;
            agg.evidence.add(
              KgEvidence(
                sourceType: group.sourceType,
                sourceId: group.sourceId,
                path: aMention.path.isNotEmpty ? aMention.path : bMention.path,
                snippet: kgSnippet('${aMention.snippet} / ${bMention.snippet}', maxLength: 100),
                occurredDate: aMention.occurredDate ?? bMention.occurredDate,
              ),
            );
          }
        }
      }
    }

    final edges = <KgEdge>[
      for (final agg in pairs.values)
        KgEdge(
          id: KgIds.edge(agg.aId, KgRelation.coOccursWith, agg.bId),
          sourceId: agg.aId,
          targetId: agg.bId,
          relation: KgRelation.coOccursWith,
          confidence: KgConfidence.inferred,
          confidenceScore: 0.6,
          weight: agg.weight,
          evidence: agg.evidence,
          firstSeenAt: now,
          lastSeenAt: now,
          updatedAt: now,
        ),
    ];
    await _repo.replaceCoOccurrenceEdges(edges);
  }

  List<Map<String, dynamic>> _topicsFromNodes(List<KgNode> nodes, Map<String, int> communityByNode) {
    final groups = <int, List<KgNode>>{};
    for (final node in nodes) {
      final communityId = communityByNode[node.id];
      if (communityId == null) continue;
      groups.putIfAbsent(communityId, () => []).add(node);
    }
    final entries = groups.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));
    final result = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final members = entry.value..sort((a, b) => b.mentionCount.compareTo(a.mentionCount));
      final label = members.take(3).map((node) => node.name).join(' · ');
      result.add({
        'community_id': entry.key,
        'label': label,
        'size': members.length,
        'top_entities': [
          for (final node in members.take(8))
            {'id': node.id, 'name': node.name, 'type': node.type, 'mention_count': node.mentionCount},
        ],
      });
    }
    return result;
  }
}

class _SourceMentions {
  final String sourceType;
  final String sourceId;
  final Map<String, KgMention> mentions = {};

  _SourceMentions({required this.sourceType, required this.sourceId});
}

class _PairAgg {
  final String aId;
  final String bId;
  double weight = 0;
  final List<KgEvidence> evidence = [];

  _PairAgg({required this.aId, required this.bId});
}
