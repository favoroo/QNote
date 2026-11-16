import 'package:qnote_flutter/core/knowledge/kg_indexer.dart';
import 'package:qnote_flutter/core/knowledge/kg_query_service.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 个人知识图谱查询工具（只读）。
///
/// 与 `grep` 的分工：`grep` 负责「找原文」，`graph` 负责「找关系」。
/// 问原因、规律、关联、建议或灵感时先查图，再按返回的证据路径读原文核实。
class GraphTool extends AgentTool {
  final KnowledgeGraphQueryService _query = KnowledgeGraphQueryService.instance;

  @override
  String get name => 'graph';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '查询个人知识图谱：实体检索、邻居关联、两实体路径、实体出现时间线、关联发现、主题社区与图谱概览。'
      '当用户问「为什么 / 和什么有关 / 最近有什么规律 / 给点建议或灵感」时优先使用，'
      '再根据返回的证据路径用 read_file 核实原文。返回的 INFERRED/AMBIGUOUS 关系只是线索，'
      '不得说成事实；相关性不等于因果。';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'op': {
        'type': 'string',
        'enum': ['search', 'neighbors', 'path', 'timeline', 'insights', 'stats', 'community'],
        'description':
            '查询类型：search 找实体；neighbors 看邻居；path 看两实体路径；'
            'timeline 看实体出现日期；insights 看关联发现；stats 看概览；community 看主题成员',
      },
      'query': {'type': 'string', 'description': 'search 的检索词（实体名/关键词）'},
      'node': {'type': 'string', 'description': 'neighbors/timeline 的实体 id 或名称'},
      'from': {'type': 'string', 'description': 'path 的起点实体 id 或名称'},
      'to': {'type': 'string', 'description': 'path 的终点实体 id 或名称'},
      'relation': {'type': 'string', 'description': 'neighbors 可只保留某类关系，如 related_to / worsens'},
      'depth': {'type': 'integer', 'description': 'neighbors 的深度，1 或 2，默认 1'},
      'start_date': {'type': 'string', 'description': 'timeline 起始日期 YYYY-MM-DD'},
      'end_date': {'type': 'string', 'description': 'timeline 结束日期 YYYY-MM-DD'},
      'community_id': {'type': 'integer', 'description': 'community 的主题编号'},
      'max_results': {'type': 'integer', 'description': 'search/insights 的最多返回条数，默认 8/10'},
    },
    'required': ['op'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> arguments, {void Function(String progress)? onProgress}) async {
    final op = (arguments['op'] as String? ?? '').trim();
    if (op.isEmpty) return ToolResult.error('op 不能为空');

    try {
      // 图谱还没建好时不要报错：让模型回退 grep，避免它编造内容
      final stats = await _query.stats();
      final entityCount = (stats['entity_count'] as num?)?.toInt() ?? 0;
      if (entityCount == 0 && op != 'stats') {
        return ToolResult.success(
          '知识图谱尚未建立（当前 0 个实体）。请告知用户可在「设置 → 小Q → 图谱」里点「更新图谱」，'
          '或直接在统计页的「关联发现」卡片里点「建立图谱」；更新前先用 grep 在原始记录里定位关键词，'
          '不要编造关联。',
          uiDetails: {'type': 'graph_result', 'op': op, 'empty': true},
        );
      }

      // 图谱不会自动更新，查询时把数据截止时间与待整理数量一并交给模型
      final freshness = await KnowledgeGraphIndexer.instance.freshness();
      final freshnessNote = _freshnessNote(freshness);

      switch (op) {
        case 'search':
          final queryText = (arguments['query'] as String? ?? '').trim();
          if (queryText.isEmpty) return ToolResult.error('search 需要 query');
          final maxResults = _clampInt(arguments['max_results'], 8, 1, 30);
          final nodes = await _query.search(queryText, limit: maxResults);
          return _success(
            _withFreshness(_query.formatSearch(nodes, queryText), freshnessNote),
            op: op,
            detail: {'query': queryText, 'count': nodes.length},
          );

        case 'neighbors':
          final nodeText = (arguments['node'] as String? ?? '').trim();
          if (nodeText.isEmpty) return ToolResult.error('neighbors 需要 node');
          final resolution = await _query.resolveNode(nodeText);
          final ambiguous = _ambiguousResult(resolution, nodeRef: nodeText, op: op);
          if (ambiguous != null) return ambiguous;
          final node = resolution.node!;
          final depth = _clampInt(arguments['depth'], 1, 1, 2);
          final graph = await _query.neighbors(
            node,
            depth: depth,
            relation: (arguments['relation'] as String?)?.trim(),
          );
          return _success(
            _withFreshness(_query.formatNeighbors(graph), freshnessNote),
            op: op,
            detail: {'node': node.name, 'node_id': node.id, 'edges': graph.edges.length},
          );

        case 'path':
          final fromText = (arguments['from'] as String? ?? '').trim();
          final toText = (arguments['to'] as String? ?? '').trim();
          if (fromText.isEmpty || toText.isEmpty) return ToolResult.error('path 需要 from 和 to');
          final fromResolution = await _query.resolveNode(fromText);
          final fromAmbiguous = _ambiguousResult(fromResolution, nodeRef: fromText, op: op);
          if (fromAmbiguous != null) return fromAmbiguous;
          final toResolution = await _query.resolveNode(toText);
          final toAmbiguous = _ambiguousResult(toResolution, nodeRef: toText, op: op);
          if (toAmbiguous != null) return toAmbiguous;
          final path = await _query.path(fromResolution.node!, toResolution.node!);
          return _success(
            _withFreshness(_query.formatPath(path), freshnessNote),
            op: op,
            detail: {
              'from': fromResolution.node!.name,
              'to': toResolution.node!.name,
              'hops': path.edges.length,
              'found': path.found,
            },
          );

        case 'timeline':
          final nodeText = (arguments['node'] as String? ?? '').trim();
          if (nodeText.isEmpty) return ToolResult.error('timeline 需要 node');
          final resolution = await _query.resolveNode(nodeText);
          final ambiguous = _ambiguousResult(resolution, nodeRef: nodeText, op: op);
          if (ambiguous != null) return ambiguous;
          final node = resolution.node!;
          final from = kgParseDateKey(arguments['start_date']?.toString());
          final to = kgParseDateKey(arguments['end_date']?.toString());
          final mentions = await _query.timeline(node, from: from, to: to);
          return _success(
            _withFreshness(_query.formatTimeline(mentions, node.name), freshnessNote),
            op: op,
            detail: {'node': node.name, 'node_id': node.id, 'mentions': mentions.length},
          );

        case 'insights':
          final limit = _clampInt(arguments['max_results'], 10, 1, 30);
          final insights = await _query.insights(limit: limit);
          return _success(
            _withFreshness(_query.formatInsights(insights), freshnessNote),
            op: op,
            detail: {'count': insights.length},
          );

        case 'stats':
          return _success(_withFreshness(_query.formatStats(stats), freshnessNote), op: op, detail: stats);

        case 'community':
          final communityId = _clampInt(arguments['community_id'], 0, 0, 999999);
          final nodes = await _query.community(communityId);
          return _success(
            _withFreshness(_query.formatCommunity(nodes, communityId), freshnessNote),
            op: op,
            detail: {'community_id': communityId, 'count': nodes.length},
          );

        default:
          return ToolResult.error('未知 op: $op（可用 search/neighbors/path/timeline/insights/stats/community）');
      }
    } catch (e) {
      return ToolResult.error('图谱查询失败: $e');
    }
  }

  ToolResult? _ambiguousResult(KgNodeResolution resolution, {required String nodeRef, required String op}) {
    if (resolution.isAmbiguous) {
      final buffer = StringBuffer('「$nodeRef」有多个候选，请确认具体指哪一个（用 id 或更完整的名称再查）：\n');
      for (final node in resolution.candidates) {
        buffer.writeln('- ${node.name}（${KgEntityType.labels[node.type] ?? node.type}） id:${node.id}');
      }
      return ToolResult.success(
        buffer.toString(),
        uiDetails: {'type': 'graph_result', 'op': op, 'ambiguous': true, 'node': nodeRef},
      );
    }
    if (resolution.isEmpty) {
      return ToolResult.success(
        '图谱里没有找到「$nodeRef」。可以先用 graph(op:"search") 换个关键词，'
        '或 grep 原始记录确认它在数据里实际怎么写。',
        uiDetails: {'type': 'graph_result', 'op': op, 'not_found': true, 'node': nodeRef},
      );
    }
    return null;
  }

  String _withFreshness(String text, String? freshnessNote) {
    if (freshnessNote == null) return text;
    return '$text\n\n$freshnessNote';
  }

  String? _freshnessNote(KgFreshness freshness) {
    final lastScan = freshness.lastScan;
    if (lastScan == null) return null;
    if (freshness.pendingRuleCount <= 0) return null;
    return '图谱数据截至 ${_formatDateTime(lastScan)}，另有约 ${freshness.pendingRuleCount} 条新记录尚未整理；'
        '回答时可提醒用户点「更新图谱」后再看最新关联。';
  }

  static String _formatDateTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  ToolResult _success(String text, {required String op, Map<String, dynamic>? detail}) {
    return ToolResult.success(
      truncateOutput(text, maxLength: 6000),
      uiDetails: {'type': 'graph_result', 'op': op, 'detail': ?detail},
    );
  }

  int _clampInt(dynamic raw, int fallback, int min, int max) {
    final value = raw is int ? raw : (raw is num ? raw.round() : int.tryParse(raw?.toString() ?? ''));
    return (value ?? fallback).clamp(min, max);
  }
}
