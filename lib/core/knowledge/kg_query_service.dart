import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 节点解析结果：唯一命中返回 [node]，多候选返回 [candidates]。
///
/// 名称有歧义时宁可让模型看到候选再确认，也不静默选一个——「苹果」既可能是
/// 食物也可能是公司，选错会把整条关联链带偏。
class KgNodeResolution {
  final KgNode? node;
  final List<KgNode> candidates;

  const KgNodeResolution({this.node, this.candidates = const []});

  bool get isAmbiguous => node == null && candidates.length > 1;
  bool get isEmpty => node == null && candidates.isEmpty;
}

/// 查询得到的子图
class KgSubgraph {
  final KgNode center;
  final List<KgNode> nodes;
  final List<KgEdge> edges;

  const KgSubgraph({required this.center, this.nodes = const [], this.edges = const []});
}

/// 路径查询结果
class KgPathResult {
  final List<KgNode> nodes;
  final List<KgEdge> edges;
  final double confidence;

  const KgPathResult({this.nodes = const [], this.edges = const [], this.confidence = 0});

  bool get found => nodes.length >= 2 && edges.isNotEmpty;
}

/// 图查询服务：搜索、邻居、路径、时间线、洞察、主题。
///
/// 只读，不落库；所有结果都附带可读虚拟路径，agent 拿到后可按证据读原文。
/// 输出按字符预算截断，避免一次查询把上下文灌满。
class KnowledgeGraphQueryService {
  static final KnowledgeGraphQueryService instance = KnowledgeGraphQueryService._internal();
  KnowledgeGraphQueryService._internal();

  final KnowledgeGraphRepository _repo = KnowledgeGraphRepository();

  static const int defaultBudget = 2500;

  Future<KgNodeResolution> resolveNode(String ref) async {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return const KgNodeResolution();

    final byId = await _repo.getNodeById(trimmed);
    if (byId != null) return KgNodeResolution(node: byId);

    final normalized = normalizeKgName(trimmed);
    if (normalized.isNotEmpty) {
      final exactEntity = await _repo.findExactNode(normalized, kind: KgNodeKind.entity);
      if (exactEntity != null) return KgNodeResolution(node: exactEntity);
      final exactState = await _repo.findExactNode(normalized, kind: KgNodeKind.state);
      if (exactState != null) return KgNodeResolution(node: exactState);
    }

    final candidates = await _repo.searchNodes(trimmed, limit: 6);
    if (candidates.isEmpty) return const KgNodeResolution();
    if (candidates.length == 1) return KgNodeResolution(node: candidates.first);
    return KgNodeResolution(candidates: candidates);
  }

  Future<List<KgNode>> search(String query, {int limit = 8}) {
    return _repo.searchNodes(query, limit: limit);
  }

  Future<KgSubgraph> neighbors(
    KgNode center, {
    int depth = 1,
    String? relation,
    int maxNodes = 40,
    int maxEdges = 80,
  }) async {
    final visited = <String>{center.id};
    final edgesById = <String, KgEdge>{};
    var frontier = <String>[center.id];
    final relations = relation == null || relation.trim().isEmpty ? null : <String>{relation.trim()};

    for (var level = 0; level < depth.clamp(1, 2); level++) {
      final next = <String>[];
      for (final id in frontier) {
        if (visited.length >= maxNodes || edgesById.length >= maxEdges) break;
        final edges = await _repo.getEdgesForNode(id, relations: relations, limit: 120);
        for (final edge in edges) {
          if (edgesById.length >= maxEdges) break;
          edgesById[edge.id] = edge;
          final other = edge.sourceId == id ? edge.targetId : edge.sourceId;
          if (other == center.id) continue;
          if (visited.add(other)) next.add(other);
        }
      }
      frontier = next;
      if (frontier.isEmpty) break;
    }

    final nodes = await _repo.getNodesByIds(visited);
    return KgSubgraph(center: center, nodes: nodes, edges: edgesById.values.toList());
  }

  Future<KgPathResult> path(KgNode from, KgNode to, {int maxHops = 6}) async {
    if (from.id == to.id) {
      return KgPathResult(nodes: [from], edges: const [], confidence: 1.0);
    }

    final parents = <String, ({String previous, KgEdge edge})>{};
    final visited = <String>{from.id};
    var frontier = <String>[from.id];
    var found = false;

    for (var hop = 0; hop < maxHops.clamp(1, 8) && !found; hop++) {
      final next = <String>[];
      for (final id in frontier) {
        final edges = await _repo.getEdgesForNode(id, limit: 200);
        for (final edge in edges) {
          final other = edge.sourceId == id ? edge.targetId : edge.sourceId;
          if (visited.contains(other)) continue;
          visited.add(other);
          parents[other] = (previous: id, edge: edge);
          if (other == to.id) {
            found = true;
            break;
          }
          next.add(other);
        }
        if (found) break;
      }
      frontier = next;
      if (frontier.isEmpty) break;
    }

    if (!found) return const KgPathResult();

    final nodeIds = <String>[to.id];
    final edges = <KgEdge>[];
    var cursor = to.id;
    while (cursor != from.id) {
      final parent = parents[cursor];
      if (parent == null) return const KgPathResult();
      edges.insert(0, parent.edge);
      nodeIds.insert(0, parent.previous);
      cursor = parent.previous;
    }

    final nodes = await _repo.getNodesByIds(nodeIds);
    final nodeById = {for (final node in nodes) node.id: node};
    final orderedNodes = [
      for (final id in nodeIds)
        if (nodeById[id] != null) nodeById[id]!,
    ];
    var confidence = 1.0;
    for (final edge in edges) {
      if (edge.confidenceScore < confidence) confidence = edge.confidenceScore;
    }
    return KgPathResult(nodes: orderedNodes, edges: edges, confidence: confidence);
  }

  Future<List<KgMention>> timeline(KgNode node, {DateTime? from, DateTime? to, int limit = 40}) {
    return _repo.getMentionsForNode(node.id, from: from, to: to, limit: limit);
  }

  Future<List<KgInsight>> insights({int limit = 10, String? status}) {
    return _repo.getInsights(limit: limit, status: status);
  }

  Future<Map<String, dynamic>> stats() async {
    final stats = await _repo.stats();
    final top = await _repo.topEntities(limit: 12);
    return {
      ...stats,
      'top_entities': [
        for (final row in top)
          {
            'id': row['id'],
            'name': row['name'],
            'type': row['type'],
            'mention_count': row['mention_count'],
            'community_id': row['community_id'],
          },
      ],
    };
  }

  Future<List<KgNode>> community(int communityId, {int limit = 40}) async {
    final all = await _repo.getAllNodes(limit: 5000);
    return all
        .where(
          (node) =>
              node.communityId == communityId && (node.kind == KgNodeKind.entity || node.kind == KgNodeKind.state),
        )
        .take(limit)
        .toList();
  }

  // ==========================================
  // 输出排版：紧凑 Markdown + 可读路径
  // ==========================================

  String formatSearch(List<KgNode> nodes, String query, {int budget = defaultBudget}) {
    if (nodes.isEmpty) {
      return '未找到与「$query」匹配的实体或状态。可换个说法，或先用 grep 在原始记录里找关键词。';
    }
    final buffer = StringBuffer('与「$query」相关的图谱节点（按相关度排序）：\n');
    for (final node in nodes) {
      buffer.write(
        '\n- ${node.name}（${_typeLabel(node)}，提及 ${node.mentionCount} 次）'
        ' id:${node.id}',
      );
      if (node.aliases.isNotEmpty) {
        buffer.write(' | 别名: ${node.aliases.take(3).join('、')}');
      }
      if (node.summary.trim().isNotEmpty) {
        buffer.write('\n  ${kgSnippet(node.summary, maxLength: 70)}');
      }
    }
    return _budget(buffer.toString(), budget);
  }

  String formatNeighbors(KgSubgraph graph, {int budget = defaultBudget}) {
    if (graph.edges.isEmpty) {
      return '「${graph.center.name}」目前没有已建立的关联。'
          '可以先用 graph(op:"timeline") 看它出现在哪些记录，或等索引/语义抽取补充关系。';
    }
    final nodeById = {for (final node in graph.nodes) node.id: node};
    final buffer = StringBuffer('「${graph.center.name}」的关联（${graph.edges.length} 条边，${graph.nodes.length} 个节点）：\n');
    final sorted = graph.edges.toList()
      ..sort((a, b) {
        final byWeight = b.weight.compareTo(a.weight);
        if (byWeight != 0) return byWeight;
        return b.confidenceScore.compareTo(a.confidenceScore);
      });
    for (final edge in sorted) {
      final source = nodeById[edge.sourceId];
      final target = nodeById[edge.targetId];
      final other = edge.sourceId == graph.center.id ? target : source;
      final direction = edge.sourceId == graph.center.id ? '→' : '←';
      buffer.writeln(
        '\n- ${graph.center.name} $direction '
        '${other?.name ?? (edge.sourceId == graph.center.id ? edge.targetId : edge.sourceId)}'
        ' [${KgRelation.labels[edge.relation] ?? edge.relation}]'
        ' ${edge.confidence} ${edge.confidenceScore.toStringAsFixed(2)}'
        ' · 权重 ${edge.weight.toStringAsFixed(1)}',
      );
      final evidence = edge.evidence.take(2).toList();
      for (final item in evidence) {
        if (item.path.isNotEmpty) {
          buffer.writeln(
            '  证据: ${item.path}${item.occurredDate == null ? '' : '（${item.occurredDate}）'}'
            '${item.snippet.isEmpty ? '' : ' 「${kgSnippet(item.snippet, maxLength: 50)}」'}',
          );
        }
      }
    }
    return _budget(buffer.toString(), budget);
  }

  String formatPath(KgPathResult path, {int budget = defaultBudget}) {
    if (!path.found) return '未找到两个节点之间的路径。可以试试更短的关键词，或分别查各自的邻居。';
    final buffer = StringBuffer(
      '路径（${path.edges.length} 跳，整体置信度取最弱一跳 '
      '${path.confidence.toStringAsFixed(2)}）：\n',
    );
    final names = <String>[for (var i = 0; i < path.nodes.length; i++) path.nodes[i].name];
    buffer.writeln('\n${names.join('  →  ')}');
    for (var i = 0; i < path.edges.length; i++) {
      final edge = path.edges[i];
      final from = path.nodes[i];
      final to = path.nodes[i + 1];
      buffer.writeln(
        '\n- ${from.name} —[${KgRelation.labels[edge.relation] ?? edge.relation}]→ ${to.name}'
        ' · ${edge.confidence} ${edge.confidenceScore.toStringAsFixed(2)}',
      );
      final evidence = edge.evidence.firstOrNull;
      if (evidence != null && evidence.path.isNotEmpty) {
        buffer.writeln('  证据: ${evidence.path}');
      }
    }
    return _budget(buffer.toString(), budget);
  }

  String formatTimeline(List<KgMention> mentions, String nodeName, {int budget = defaultBudget}) {
    if (mentions.isEmpty) return '「$nodeName」在指定区间内没有提及记录。';
    final grouped = <String, List<KgMention>>{};
    for (final mention in mentions) {
      final key = mention.occurredDate ?? '未知日期';
      grouped.putIfAbsent(key, () => []).add(mention);
    }
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final buffer = StringBuffer('「$nodeName」的出现记录（${dates.length} 天）：\n');
    for (final date in dates.take(30)) {
      final items = grouped[date]!;
      buffer.writeln('\n- $date（${items.length} 条）');
      for (final item in items.take(3)) {
        buffer.writeln(
          '  ${item.path.isEmpty ? item.sourceType : item.path}'
          '${item.snippet.isEmpty ? '' : ' 「${kgSnippet(item.snippet, maxLength: 60)}」'}',
        );
      }
    }
    return _budget(buffer.toString(), budget);
  }

  String formatInsights(List<KgInsight> insights, {int budget = defaultBudget}) {
    if (insights.isEmpty) {
      return '暂未积累足够数据生成关联发现（需要至少 3–4 天重复出现才能统计）。';
    }
    final buffer = StringBuffer('关联发现（${insights.length} 条）：\n');
    for (final insight in insights) {
      buffer.writeln('\n- ${insight.title}');
      buffer.writeln('  ${insight.body}');
      buffer.writeln(
        '  支持 ${insight.support} 天 · 置信度 ${insight.confidence.toStringAsFixed(2)}'
        ' · 提升度 ${insight.lift.toStringAsFixed(2)} · ${insight.kind}',
      );
      final evidence = insight.evidence.take(3).toList();
      for (final item in evidence) {
        if (item.path.isNotEmpty) {
          buffer.writeln('  证据: ${item.path}${item.occurredDate == null ? '' : '（${item.occurredDate}）'}');
        }
      }
    }
    return _budget(buffer.toString(), budget);
  }

  String formatStats(Map<String, dynamic> stats, {int budget = defaultBudget}) {
    int intOf(String key) => (stats[key] as num?)?.toInt() ?? 0;
    final buffer = StringBuffer('个人知识图谱概览：\n');
    buffer.writeln(
      '- 实体 ${intOf('entity_count')} 个，状态 ${intOf('state_count')} 个，'
      '源记录 ${intOf('source_count')} 条',
    );
    buffer.writeln(
      '- 关系 ${intOf('edge_count')} 条，提及 ${intOf('mention_count')} 条，'
      '洞察 ${intOf('insight_count')} 条',
    );
    buffer.writeln('- 最近索引: ${stats['last_scan_at'] ?? '尚未完成'}');
    final top = stats['top_entities'];
    if (top is List && top.isNotEmpty) {
      buffer.writeln('\n高频实体：');
      for (final raw in top.take(12)) {
        if (raw is! Map) continue;
        buffer.writeln(
          '- ${raw['name']}（${KgEntityType.labels[raw['type']] ?? raw['type']}，'
          '${raw['mention_count']} 次） id:${raw['id']}',
        );
      }
    }
    return _budget(buffer.toString(), budget);
  }

  String formatCommunity(List<KgNode> nodes, int communityId, {int budget = defaultBudget}) {
    if (nodes.isEmpty) return '主题 $communityId 暂无成员，或社区尚未重算。';
    final buffer = StringBuffer('主题 $communityId 的成员（${nodes.length} 个）：\n');
    for (final node in nodes) {
      buffer.writeln('- ${node.name}（${_typeLabel(node)}，提及 ${node.mentionCount} 次） id:${node.id}');
    }
    return _budget(buffer.toString(), budget);
  }

  String _typeLabel(KgNode node) {
    if (node.kind == KgNodeKind.state) return '状态';
    if (node.kind == KgNodeKind.day) return '日期';
    if (node.kind == KgNodeKind.source) return '源记录';
    return KgEntityType.labels[node.type] ?? node.type;
  }

  String _budget(String text, int budget) {
    if (text.length <= budget) return text;
    return '${text.substring(0, budget)}\n…（已按预算截断，可用更具体的关键词缩小范围）';
  }
}
