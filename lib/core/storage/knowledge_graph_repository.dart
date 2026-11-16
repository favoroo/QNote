import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 知识图谱数据访问层。
///
/// 所有 `kg_*` 表都是派生数据：不写 `sync_log`、不参与备份导出；写入失败只影响
/// 图谱本身，不应阻塞业务数据的保存。节点/边/提及的写入统一走这里，避免
/// VFS、索引器、洞察服务各自拼 SQL。
class KnowledgeGraphRepository {
  static final KnowledgeGraphRepository _instance = KnowledgeGraphRepository._internal();
  factory KnowledgeGraphRepository() => _instance;
  KnowledgeGraphRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<Database> get _db async => _dbHelper.database;

  // ==========================================
  // 节点
  // ==========================================

  Future<void> upsertNode(KgNode node) async {
    final db = await _db;
    await db.insert('kg_nodes', node.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertNodes(List<KgNode> nodes) async {
    if (nodes.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final node in nodes) {
      batch.insert('kg_nodes', node.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<KgNode?> getNodeById(String id) async {
    final db = await _db;
    final rows = await db.query('kg_nodes', where: 'id = ? AND is_deleted = 0', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return KgNode.fromMap(rows.first);
  }

  Future<KgNode?> getSourceNode(String sourceType, String sourceId) async {
    final db = await _db;
    final rows = await db.query(
      'kg_nodes',
      where: 'source_type = ? AND source_id = ? AND is_deleted = 0',
      whereArgs: [sourceType, sourceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return KgNode.fromMap(rows.first);
  }

  Future<List<KgNode>> getNodesByIds(Iterable<String> ids) async {
    final unique = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return const [];
    final db = await _db;
    final result = <KgNode>[];
    // SQLite 的变量个数有上限（老版本 999），按 500 分段避免大图查询直接报错
    for (var i = 0; i < unique.length; i += 500) {
      final chunk = unique.sublist(i, math.min(i + 500, unique.length));
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query('kg_nodes', where: 'id IN ($placeholders) AND is_deleted = 0', whereArgs: chunk);
      result.addAll(rows.map((m) => KgNode.fromMap(m)));
    }
    return result;
  }

  Future<List<KgNode>> getAllNodes({String? kind, int limit = 5000}) async {
    final db = await _db;
    final rows = await db.query(
      'kg_nodes',
      where: kind == null ? 'is_deleted = 0' : 'kind = ? AND is_deleted = 0',
      whereArgs: kind == null ? null : [kind],
      limit: limit,
    );
    return rows.map((m) => KgNode.fromMap(m)).toList();
  }

  /// 精确匹配归一名（同 kind、可选同 type），命中节点名或别名。
  Future<KgNode?> findExactNode(String normalizedName, {String kind = KgNodeKind.entity, String? type}) async {
    if (normalizedName.isEmpty) return null;
    final db = await _db;
    final typeClause = type == null ? '' : ' AND type = ?';
    final typeArgs = type == null ? <Object>[] : <Object>[type];

    final direct = await db.rawQuery(
      'SELECT * FROM kg_nodes WHERE normalized_name = ? AND kind = ?$typeClause AND is_deleted = 0 LIMIT 1',
      [normalizedName, kind, ...typeArgs],
    );
    if (direct.isNotEmpty) return KgNode.fromMap(direct.first);

    final aliasRows = await db.rawQuery(
      'SELECT n.* FROM kg_aliases a JOIN kg_nodes n ON n.id = a.entity_id '
      'WHERE a.normalized_alias = ? AND n.kind = ?$typeClause AND n.is_deleted = 0 LIMIT 1',
      [normalizedName, kind, ...typeArgs],
    );
    if (aliasRows.isNotEmpty) return KgNode.fromMap(aliasRows.first);
    return null;
  }

  /// 关键词搜索实体/状态节点：先按归一名/原名/别名粗筛，再在 Dart 侧打分。
  ///
  /// 不使用 SQL 的 `%词%` 排序（中文短词命中太多且无法按相关度排），
  /// 粗筛最多取 200 条候选，足够个人图谱量级。
  Future<List<KgNode>> searchNodes(String query, {int limit = 20, String? kind}) async {
    final tokens = kgTokenize(query);
    final normalized = normalizeKgName(query);
    if (tokens.isEmpty && normalized.isEmpty) return const [];

    final conditions = <String>[];
    final args = <Object>[];
    final kindClause = kind == null ? "kind IN ('entity','state')" : 'kind = ?';
    if (kind != null) args.add(kind);

    for (final token in tokens.take(6)) {
      conditions.add('(normalized_name LIKE ? OR aliases LIKE ?)');
      args.add('%$token%');
      args.add('%$token%');
    }
    if (normalized.isNotEmpty) {
      conditions.add('normalized_name = ?');
      args.add(normalized);
      // 单字/短词（如「头」「成都」）分词后可能只剩整段，精确匹配不够，
      // 补一条包含匹配让歧义候选能浮出来
      conditions.add('(normalized_name LIKE ? OR aliases LIKE ?)');
      args.add('%$normalized%');
      args.add('%$normalized%');
    }
    if (conditions.isEmpty) return const [];

    final db = await _db;
    final rows = await db.query(
      'kg_nodes',
      where: '$kindClause AND is_deleted = 0 AND (${conditions.join(' OR ')})',
      whereArgs: args,
      limit: 200,
    );

    final scored = <(double, KgNode)>[];
    for (final row in rows) {
      final node = KgNode.fromMap(row);
      final score = _scoreNode(node, query, tokens);
      if (score > 0) scored.add((score, node));
    }
    scored.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      if (byScore != 0) return byScore;
      return b.$2.mentionCount.compareTo(a.$2.mentionCount);
    });
    return scored.take(limit).map((e) => e.$2).toList();
  }

  double _scoreNode(KgNode node, String rawQuery, List<String> tokens) {
    final query = normalizeKgName(rawQuery);
    final name = node.normalizedName;
    var score = 0.0;
    if (query.isNotEmpty && name == query) {
      score += 100;
    } else if (query.isNotEmpty && name.startsWith(query)) {
      score += 60;
    } else if (query.isNotEmpty && name.contains(query)) {
      score += 30;
    } else if (query.isNotEmpty && query.contains(name) && name.length >= 2) {
      score += 20;
    }

    for (final alias in node.aliases) {
      final normalizedAlias = normalizeKgName(alias);
      if (normalizedAlias == query && query.isNotEmpty) score += 80;
      if (normalizedAlias.contains(query) && query.isNotEmpty) score += 12;
    }

    var overlap = 0;
    for (final token in tokens) {
      if (name.contains(token)) {
        overlap++;
      } else if (node.aliases.any((alias) => normalizeKgName(alias).contains(token))) {
        overlap++;
      }
    }
    score += overlap * 8;
    // 提及次数只做温和加权，避免高频泛词压过精确匹配
    score += node.mentionCount <= 0 ? 0 : math.log(node.mentionCount.clamp(1, 200) + 1) / math.ln2;
    return score;
  }

  Future<void> updateCommunityIds(Map<String, int?> communityByNodeId) async {
    if (communityByNodeId.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final entry in communityByNodeId.entries) {
      batch.update(
        'kg_nodes',
        {'community_id': entry.value, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  // ==========================================
  // 别名
  // ==========================================

  Future<void> upsertAlias({required String entityId, required String alias, String origin = 'auto'}) async {
    final normalized = normalizeKgName(alias);
    if (normalized.isEmpty) return;
    final db = await _db;
    await db.insert('kg_aliases', {
      'id': 'alias_${entityId}_$normalized',
      'entity_id': entityId,
      'alias': alias.trim(),
      'normalized_alias': normalized,
      'origin': origin,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> replaceAliases(String entityId, Iterable<String> aliases, {String origin = 'auto'}) async {
    final db = await _db;
    await db.delete('kg_aliases', where: 'entity_id = ?', whereArgs: [entityId]);
    for (final alias in aliases) {
      await upsertAlias(entityId: entityId, alias: alias, origin: origin);
    }
  }

  // ==========================================
  // 边
  // ==========================================

  /// 写入/合并一条边。
  ///
  /// 相同 (source, target, relation) 视为同一条边：置信度取更强的一档，
  /// 权重累加，证据按「来源类型+来源 id+路径」去重合并。共现边由洞察服务
  /// 周期性整体重算，不走这里的累加语义。
  Future<void> upsertEdge(KgEdge edge) async {
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'kg_edges',
        where: 'source_id = ? AND target_id = ? AND relation = ?',
        whereArgs: [edge.sourceId, edge.targetId, edge.relation],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('kg_edges', edge.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
        return;
      }
      final existing = KgEdge.fromMap(rows.first);
      final mergedEvidence = <String, KgEvidence>{
        for (final e in existing.evidence) '${e.sourceType}|${e.sourceId}|${e.path}': e,
        for (final e in edge.evidence) '${e.sourceType}|${e.sourceId}|${e.path}': e,
      };
      final stronger = _strongerConfidence(existing.confidence, edge.confidence);
      final merged = existing.copyWith(
        confidence: stronger,
        confidenceScore: existing.confidenceScore > edge.confidenceScore
            ? existing.confidenceScore
            : edge.confidenceScore,
        weight: existing.weight + edge.weight,
        evidence: mergedEvidence.values.toList(),
        lastSeenAt: edge.lastSeenAt.isAfter(existing.lastSeenAt) ? edge.lastSeenAt : existing.lastSeenAt,
        updatedAt: DateTime.now(),
      );
      await txn.update('kg_edges', merged.toMap(), where: 'id = ?', whereArgs: [existing.id]);
    });
  }

  Future<void> upsertEdges(List<KgEdge> edges) async {
    if (edges.isEmpty) return;
    // 批量场景逐条走事务太重；先按唯一键去重，再在一个事务里 upsert
    final db = await _db;
    final unique = <String, KgEdge>{
      for (final edge in edges) '${edge.sourceId}|${edge.targetId}|${edge.relation}': edge,
    };
    await db.transaction((txn) async {
      for (final edge in unique.values) {
        final rows = await txn.query(
          'kg_edges',
          where: 'source_id = ? AND target_id = ? AND relation = ?',
          whereArgs: [edge.sourceId, edge.targetId, edge.relation],
          limit: 1,
        );
        if (rows.isEmpty) {
          await txn.insert('kg_edges', edge.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
          continue;
        }
        final existing = KgEdge.fromMap(rows.first);
        final mergedEvidence = <String, KgEvidence>{
          for (final e in existing.evidence) '${e.sourceType}|${e.sourceId}|${e.path}': e,
          for (final e in edge.evidence) '${e.sourceType}|${e.sourceId}|${e.path}': e,
        };
        final merged = existing.copyWith(
          confidence: _strongerConfidence(existing.confidence, edge.confidence),
          confidenceScore: existing.confidenceScore > edge.confidenceScore
              ? existing.confidenceScore
              : edge.confidenceScore,
          weight: existing.weight + edge.weight,
          evidence: mergedEvidence.values.toList(),
          lastSeenAt: edge.lastSeenAt.isAfter(existing.lastSeenAt) ? edge.lastSeenAt : existing.lastSeenAt,
          updatedAt: DateTime.now(),
        );
        await txn.update('kg_edges', merged.toMap(), where: 'id = ?', whereArgs: [existing.id]);
      }
    });
  }

  Future<List<KgEdge>> getEdgesForNode(String nodeId, {Iterable<String>? relations, int limit = 200}) async {
    final db = await _db;
    final relationClause = relations == null || relations.isEmpty
        ? ''
        : ' AND relation IN (${List.filled(relations.length, '?').join(',')})';
    final args = <Object>[nodeId, nodeId, ...?relations];
    final rows = await db.query(
      'kg_edges',
      where: '(source_id = ? OR target_id = ?) AND is_deleted = 0$relationClause',
      whereArgs: args,
      orderBy: 'weight DESC, confidence_score DESC',
      limit: limit,
    );
    return rows.map((m) => KgEdge.fromMap(m)).toList();
  }

  Future<List<KgEdge>> getEdgesAmongKinds({
    Set<String> kinds = const {KgNodeKind.entity, KgNodeKind.state},
    int limit = 20000,
  }) async {
    final db = await _db;
    final placeholders = List.filled(kinds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT e.* FROM kg_edges e '
      'JOIN kg_nodes s ON s.id = e.source_id AND s.kind IN ($placeholders) AND s.is_deleted = 0 '
      'JOIN kg_nodes t ON t.id = e.target_id AND t.kind IN ($placeholders) AND t.is_deleted = 0 '
      'WHERE e.is_deleted = 0 AND e.relation NOT IN (?, ?) '
      'ORDER BY e.weight DESC LIMIT ?',
      [...kinds, ...kinds, KgRelation.partOf, KgRelation.belongsTo, limit],
    );
    return rows.map((m) => KgEdge.fromMap(m)).toList();
  }

  /// 清空共现边：洞察服务会按最新提及整体重算，避免旧权重累积失真
  Future<void> deleteCoOccurrenceEdges() async {
    final db = await _db;
    await db.delete('kg_edges', where: 'relation = ?', whereArgs: [KgRelation.coOccursWith]);
  }

  /// 用最新提及全量替换共现边。
  ///
  /// 共现边是聚合结果，不能像普通边一样只增不减：源记录删除/编辑后，
  /// 旧权重会一直残留。社区重算时按当前 mentions 重算一次（个人量级可接受）。
  Future<void> replaceCoOccurrenceEdges(List<KgEdge> edges) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('kg_edges', where: 'relation = ?', whereArgs: [KgRelation.coOccursWith]);
      if (edges.isEmpty) return;
      final batch = txn.batch();
      for (final edge in edges) {
        batch.insert('kg_edges', edge.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  // ==========================================
  // 提及
  // ==========================================

  Future<void> upsertMention(KgMention mention) async {
    final db = await _db;
    await db.insert('kg_mentions', mention.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertMentions(List<KgMention> mentions) async {
    if (mentions.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final mention in mentions) {
      batch.insert('kg_mentions', mention.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<KgMention>> getMentionsForNode(String nodeId, {DateTime? from, DateTime? to, int limit = 100}) async {
    final db = await _db;
    final conditions = <String>['node_id = ?'];
    final args = <Object>[nodeId];
    if (from != null) {
      conditions.add('occurred_date >= ?');
      args.add(kgDateKey(from));
    }
    if (to != null) {
      conditions.add('occurred_date <= ?');
      args.add(kgDateKey(to));
    }
    final rows = await db.query(
      'kg_mentions',
      where: conditions.join(' AND '),
      whereArgs: args,
      orderBy: 'occurred_date DESC, occurred_at DESC',
      limit: limit,
    );
    return rows.map((m) => KgMention.fromMap(m)).toList();
  }

  Future<List<KgMention>> getMentionsInRange(DateTime from, DateTime to, {int limit = 50000}) async {
    final db = await _db;
    final rows = await db.query(
      'kg_mentions',
      where: 'occurred_date >= ? AND occurred_date <= ?',
      whereArgs: [kgDateKey(from), kgDateKey(to)],
      orderBy: 'occurred_date ASC',
      limit: limit,
    );
    return rows.map((m) => KgMention.fromMap(m)).toList();
  }

  Future<List<KgMention>> getMentionsForSource(String sourceType, String sourceId) async {
    final db = await _db;
    final rows = await db.query(
      'kg_mentions',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [sourceType, sourceId],
      orderBy: 'occurred_date ASC',
    );
    return rows.map((m) => KgMention.fromMap(m)).toList();
  }

  // ==========================================
  // 增量文档状态
  // ==========================================

  Future<KgDocument?> getDocument(String sourceType, String sourceId) async {
    final db = await _db;
    final rows = await db.query(
      'kg_documents',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [sourceType, sourceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return KgDocument.fromMap(rows.first);
  }

  Future<List<KgDocument>> getDocumentsBySourceType(String sourceType) async {
    final db = await _db;
    final rows = await db.query('kg_documents', where: 'source_type = ?', whereArgs: [sourceType]);
    return rows.map((m) => KgDocument.fromMap(m)).toList();
  }

  Future<void> upsertDocument(KgDocument document) async {
    final db = await _db;
    await db.insert('kg_documents', document.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteDocument(String sourceType, String sourceId) async {
    final db = await _db;
    await db.delete('kg_documents', where: 'source_type = ? AND source_id = ?', whereArgs: [sourceType, sourceId]);
  }

  // ==========================================
  // 洞察
  // ==========================================

  Future<List<KgInsight>> getInsights({int limit = 20, String? status}) async {
    final db = await _db;
    final rows = await db.query(
      'kg_insights',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'score DESC, updated_at DESC',
      limit: limit,
    );
    return rows.map((m) => KgInsight.fromMap(m)).toList();
  }

  /// 用最新一批洞察替换 `new` 状态；用户已忽略（dismissed）的洞察不会复活
  Future<void> replaceInsights(List<KgInsight> insights) async {
    final db = await _db;
    await db.transaction((txn) async {
      final dismissedRows = await txn.query(
        'kg_insights',
        columns: ['id'],
        where: 'status = ?',
        whereArgs: ['dismissed'],
      );
      final dismissed = dismissedRows.map((r) => r['id'] as String).toSet();
      await txn.delete('kg_insights', where: 'status = ?', whereArgs: ['new']);
      final batch = txn.batch();
      for (final insight in insights) {
        if (dismissed.contains(insight.id)) continue;
        batch.insert('kg_insights', insight.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateInsightStatus(String id, String status) async {
    final db = await _db;
    await db.update(
      'kg_insights',
      {'status': status, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==========================================
  // 元信息 / 统计 / 清理
  // ==========================================

  Future<String?> getMeta(String key) async {
    final db = await _db;
    final rows = await db.query('kg_meta', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await _db;
    await db.insert('kg_meta', {
      'key': key,
      'value': value,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DateTime?> getMetaDate(String key) async {
    final raw = await getMeta(key);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<Map<String, dynamic>> stats() async {
    final db = await _db;
    Future<int> count(String sql, [List<Object>? args]) async {
      final rows = await db.rawQuery(sql, args);
      final value = rows.isEmpty ? null : rows.first.values.first;
      return (value as num?)?.toInt() ?? 0;
    }

    final entityCount = await count("SELECT COUNT(*) FROM kg_nodes WHERE kind = 'entity' AND is_deleted = 0");
    final stateCount = await count("SELECT COUNT(*) FROM kg_nodes WHERE kind = 'state' AND is_deleted = 0");
    final sourceCount = await count("SELECT COUNT(*) FROM kg_nodes WHERE kind = 'source' AND is_deleted = 0");
    final edgeCount = await count('SELECT COUNT(*) FROM kg_edges WHERE is_deleted = 0');
    final mentionCount = await count('SELECT COUNT(*) FROM kg_mentions');
    final documentCount = await count('SELECT COUNT(*) FROM kg_documents');
    final insightCount = await count("SELECT COUNT(*) FROM kg_insights WHERE status = 'new'");
    final lastIndexedAt = await getMeta('last_scan_at');
    final lastInsightAt = await getMeta('last_insight_at');
    final lastCommunityAt = await getMeta('last_community_at');

    return {
      'entity_count': entityCount,
      'state_count': stateCount,
      'source_count': sourceCount,
      'edge_count': edgeCount,
      'mention_count': mentionCount,
      'document_count': documentCount,
      'insight_count': insightCount,
      'last_scan_at': lastIndexedAt,
      'last_insight_at': lastInsightAt,
      'last_community_at': lastCommunityAt,
    };
  }

  Future<List<Map<String, dynamic>>> topEntities({int limit = 20}) async {
    final db = await _db;
    return db.query(
      'kg_nodes',
      columns: ['id', 'type', 'name', 'summary', 'mention_count', 'importance', 'community_id'],
      where: "kind IN ('entity','state') AND is_deleted = 0",
      orderBy: 'importance DESC, mention_count DESC',
      limit: limit,
    );
  }

  Future<void> clearAll() async {
    final db = await _db;
    await db.transaction((txn) async {
      for (final table in const [
        'kg_nodes',
        'kg_aliases',
        'kg_edges',
        'kg_mentions',
        'kg_documents',
        'kg_insights',
        'kg_meta',
      ]) {
        await txn.delete(table);
      }
    });
  }

  /// 删除一条源记录对图谱的全部贡献。
  ///
  /// 源记录自身的结构边直接删；实体之间的边则从证据列表里摘掉该来源，
  /// 证据被摘空时才删边。删除是低频操作，扫一遍证据可接受。
  Future<void> deleteSourceData(String sourceType, String sourceId) async {
    final db = await _db;
    final sourceNodeId = 'source:$sourceType:$sourceId';
    await db.transaction((txn) async {
      await txn.delete('kg_mentions', where: 'source_type = ? AND source_id = ?', whereArgs: [sourceType, sourceId]);
      await txn.delete('kg_edges', where: 'source_id = ? OR target_id = ?', whereArgs: [sourceNodeId, sourceNodeId]);

      final rows = await txn.query('kg_edges', where: 'evidence LIKE ?', whereArgs: ['%$sourceId%']);
      for (final row in rows) {
        final edge = KgEdge.fromMap(row);
        final kept = edge.evidence.where((e) => !(e.sourceType == sourceType && e.sourceId == sourceId)).toList();
        if (kept.length == edge.evidence.length) continue;
        if (kept.isEmpty) {
          await txn.delete('kg_edges', where: 'id = ?', whereArgs: [edge.id]);
          continue;
        }
        await txn.update(
          'kg_edges',
          {'evidence': KgEvidence.encodeList(kept), 'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [edge.id],
        );
      }

      await txn.delete('kg_nodes', where: 'id = ?', whereArgs: [sourceNodeId]);
      await txn.delete('kg_documents', where: 'source_type = ? AND source_id = ?', whereArgs: [sourceType, sourceId]);
      // 语义抽取的增量标记也属于该源记录，删除后重新建图不应命中旧 hash
      await txn.delete(
        'kg_meta',
        where: 'key IN (?, ?)',
        whereArgs: ['semantic_ok:$sourceType:$sourceId', 'semantic_attempt:$sourceType:$sourceId'],
      );
    });
  }

  /// 重新统计每个节点的提及次数与重要度。
  ///
  /// 重要度 = 提及次数的对数 × 邻居权重和的温和函数；只用于排序与查询预算，
  /// 不参与洞察的统计显著性计算。
  Future<void> refreshNodeStats() async {
    final db = await _db;
    await db.execute('''
      UPDATE kg_nodes
      SET mention_count = (
        SELECT COUNT(*) FROM kg_mentions m
        WHERE m.node_id = kg_nodes.id
      )
      WHERE kind IN ('entity','state')
    ''');
    await db.execute('''
      UPDATE kg_nodes
      SET importance = (
        SELECT COUNT(*) FROM kg_mentions m
        WHERE m.node_id = kg_nodes.id
      ) * 1.0
      WHERE kind IN ('entity','state')
    ''');
  }

  static String _strongerConfidence(String a, String b) {
    int rank(String value) {
      switch (value) {
        case KgConfidence.extracted:
          return 3;
        case KgConfidence.inferred:
          return 2;
        default:
          return 1;
      }
    }

    return rank(a) >= rank(b) ? a : b;
  }
}
