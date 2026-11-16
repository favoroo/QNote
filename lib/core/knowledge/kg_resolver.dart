import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 图谱节点的确定性 id 规则。
///
/// 源记录/日期/状态用确定性 id，重复索引时天然 upsert；实体用 uuid，
/// 因为同一实体可能从多个来源被识别，不能把名字写死进主键。
abstract final class KgIds {
  static const Uuid _uuid = Uuid();

  static String source(String sourceType, String sourceId) => 'source:$sourceType:$sourceId';

  static String day(String dateKey) => 'day:$dateKey';

  static String state(String stateType) => 'state:$stateType';

  static String entity() => 'entity:${_uuid.v4()}';

  static String edge(String sourceId, String relation, String targetId) =>
      'edge:${_uuid.v5(Namespace.url.value, '$sourceId|$relation|$targetId')}';

  static String mention(String nodeId, String sourceType, String sourceId, String field) =>
      'mention:${_uuid.v5(Namespace.url.value, '$nodeId|$sourceType|$sourceId|$field')}';

  static String insight(String kind, String aId, String bId) =>
      'insight:${_uuid.v5(Namespace.url.value, '$kind|$aId|$bId')}';
}

/// 实体解析：先精确匹配归一名/别名，找不到再创建。
///
/// 第一版只做「同类型精确匹配」；模糊合并必须过数字、前缀、长度、共现等
/// guard rail，留到语义抽取阶段做批量消歧，避免建图过程中把「苹果（食物）」
/// 和「苹果（公司）」这类同名实体静默合并。
class KgResolver {
  final KnowledgeGraphRepository _repo;

  KgResolver({KnowledgeGraphRepository? repository}) : _repo = repository ?? KnowledgeGraphRepository();

  /// 解析或创建实体节点。
  ///
  /// [aliases] 是原文中出现的同义写法；命中既有节点时追加为新别名，
  /// 方便后续查询「拿铁」也能找到「咖啡」。
  Future<KgNode> resolveEntity({
    required String name,
    required String type,
    Iterable<String> aliases = const [],
    String summary = '',
    Map<String, dynamic> metadata = const {},
  }) async {
    final cleanName = name.trim();
    final normalized = normalizeKgName(cleanName);
    final normalizedType = KgEntityType.normalize(type);
    if (normalized.isEmpty) {
      throw ArgumentError('实体名不能为空');
    }

    final existing = await _repo.findExactNode(normalized, kind: KgNodeKind.entity, type: normalizedType);
    if (existing != null) {
      final mergedAliases = <String>{
        ...existing.aliases,
        for (final alias in aliases)
          if (normalizeKgName(alias).isNotEmpty) alias.trim(),
      }.toList();
      final updated = existing.copyWith(
        aliases: mergedAliases,
        summary: summary.isNotEmpty ? summary : existing.summary,
        metadata: {...existing.metadata, ...metadata},
        updatedAt: DateTime.now(),
      );
      await _repo.upsertNode(updated);
      for (final alias in mergedAliases) {
        await _repo.upsertAlias(entityId: existing.id, alias: alias);
      }
      return updated;
    }

    final now = DateTime.now();
    final node = KgNode(
      id: KgIds.entity(),
      kind: KgNodeKind.entity,
      type: normalizedType,
      name: cleanName,
      normalizedName: normalized,
      aliases: {
        for (final alias in aliases)
          if (normalizeKgName(alias).isNotEmpty) alias.trim(),
      }.toList(),
      summary: summary,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsertNode(node);
    for (final alias in node.aliases) {
      await _repo.upsertAlias(entityId: node.id, alias: alias);
    }
    return node;
  }

  /// 解析或创建规则状态节点（确定性 id）。
  Future<KgNode> resolveState({
    required String stateType,
    required String name,
    String summary = '',
    Map<String, dynamic> metadata = const {},
  }) async {
    final id = KgIds.state(stateType);
    final existing = await _repo.getNodeById(id);
    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        name: name,
        summary: summary.isNotEmpty ? summary : existing.summary,
        metadata: {...existing.metadata, ...metadata},
        updatedAt: now,
      );
      await _repo.upsertNode(updated);
      return updated;
    }
    final node = KgNode(
      id: id,
      kind: KgNodeKind.state,
      type: stateType,
      name: name,
      normalizedName: normalizeKgName(name),
      summary: summary,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsertNode(node);
    return node;
  }

  /// 确保日期节点存在，返回节点。
  Future<KgNode> ensureDayNode(String dateKey, {Map<String, dynamic> metadata = const {}}) async {
    final id = KgIds.day(dateKey);
    final existing = await _repo.getNodeById(id);
    final now = DateTime.now();
    if (existing != null) {
      if (metadata.isEmpty) return existing;
      final updated = existing.copyWith(metadata: {...existing.metadata, ...metadata}, updatedAt: now);
      await _repo.upsertNode(updated);
      return updated;
    }
    final node = KgNode(
      id: id,
      kind: KgNodeKind.day,
      type: 'day',
      name: dateKey,
      normalizedName: dateKey.replaceAll('-', ''),
      occurredDate: dateKey,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsertNode(node);
    return node;
  }
}
