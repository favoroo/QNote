import 'dart:convert';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/knowledge/kg_dictionaries.dart';
import 'package:qnote_flutter/core/knowledge/kg_extractor.dart';
import 'package:qnote_flutter/core/knowledge/kg_prompts.dart';
import 'package:qnote_flutter/core/knowledge/kg_resolver.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 语义抽取结果：已解析成图谱节点/边/提及，由索引器与规则结果合并。
class KgSemanticResult {
  final List<KgNode> nodes;
  final List<KgEdge> edges;
  final List<KgMention> mentions;
  final String summary;

  const KgSemanticResult({this.nodes = const [], this.edges = const [], this.mentions = const [], this.summary = ''});
}

/// 笔记/日记的 LLM 语义抽取。
///
/// 复用「时间线提取模型」角色与 `AiService.chat`，不新增模型绑定；输出必须
/// 过代码侧校验：实体名要出现在原文，关系证据要能在原文逐字找到，否则丢弃。
/// 这样即使模型胡编，脏关系也进不了图谱。
class KgLlmExtractor {
  final KgResolver _resolver;

  /// 测试注入：直接返回模型文本，跳过角色配置与网络请求
  final Future<String> Function(List<ChatMessage> messages)? chatOverride;

  KgLlmExtractor({KnowledgeGraphRepository? repository, KgResolver? resolver, this.chatOverride})
    : _resolver = resolver ?? KgResolver(repository: repository);

  static const int maxChunkChars = 4000;
  static const int maxChunks = 2;

  Future<KgSemanticResult?> extract(KgSourceDocument doc) async {
    final text = doc.body.trim();
    if (text.length < 40) return null;

    AiService? service;
    if (chatOverride == null) {
      if (!await AiRoleService.instance.hasUsableConfigForRole('timelineOptimization')) {
        return null;
      }
      final config = await AiRoleService.instance.getEffectiveConfigForRole('timelineOptimization');
      final settings = await AiRoleService.instance.getSettingsForRole('timelineOptimization');
      service = AiService();
      service.updateConfig(
        config,
        temperature: settings.temperature.clamp(0.0, 0.5).toDouble(),
        maxTokens: settings.maxTokens < 2048 ? 2048 : settings.maxTokens,
      );
    }

    final chunks = _chunk(text);
    final entities = <String, _SemanticEntity>{};
    final relations = <_SemanticRelation>[];
    var summary = '';

    for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      final chunk = chunks[chunkIndex];
      Map<String, dynamic> json;
      try {
        final messages = [
          ChatMessage(role: 'system', content: KgPrompts.systemPrompt),
          ChatMessage(
            role: 'user',
            content: KgPrompts.userMessage(title: chunkIndex == 0 ? doc.title : '', body: chunk),
          ),
        ];
        final content = chatOverride != null ? await chatOverride!(messages) : await service!.chat(messages);
        final parsed = _parseJson(content);
        if (parsed == null) {
          LoggerService.instance.logAI('知识图谱语义抽取返回非 JSON，已跳过', level: LogLevel.warning);
          continue;
        }
        json = parsed;
      } catch (e, stackTrace) {
        LoggerService.instance.logAI(
          '知识图谱语义抽取失败 ${doc.sourceType}/${doc.sourceId}: $e',
          level: LogLevel.warning,
          details: stackTrace.toString(),
        );
        return null;
      }

      if (summary.isEmpty) {
        summary = (json['summary'] ?? '').toString().trim();
      }

      final chunkEntities = _validateEntities(json['entities'], chunk);
      for (final entity in chunkEntities.values) {
        final key = '${entity.type}|${normalizeKgName(entity.name)}';
        final existing = entities[key];
        if (existing == null) {
          entities[key] = entity..chunkIndexes.add(chunkIndex);
        } else {
          existing.aliases.addAll(entity.aliases);
          existing.chunkIndexes.add(chunkIndex);
        }
      }

      final validNames = {for (final entity in chunkEntities.values) normalizeKgName(entity.name): entity};
      relations.addAll(_validateRelations(json['relations'], chunk, validNames));
      if (entities.length >= 30 && relations.length >= 40) break;
    }

    if (entities.isEmpty) return const KgSemanticResult();

    final nodes = <String, KgNode>{};
    final mentions = <KgMention>[];
    final now = DateTime.now();
    final resolvedByName = <String, KgNode>{};

    for (final entity in entities.values) {
      final node = await _resolver.resolveEntity(name: entity.name, type: entity.type, aliases: entity.aliases);
      nodes[node.id] = node;
      resolvedByName[normalizeKgName(entity.name)] = node;
      for (final chunkIndex in entity.chunkIndexes) {
        final chunk = chunks[chunkIndex];
        mentions.add(
          KgMention(
            id: KgIds.mention(node.id, doc.sourceType, doc.sourceId, 'llm:$chunkIndex'),
            nodeId: node.id,
            sourceType: doc.sourceType,
            sourceId: doc.sourceId,
            path: doc.path,
            field: 'llm:$chunkIndex',
            snippet: kgSnippet(chunk, query: entity.name, maxLength: 80),
            occurredAt: doc.occurredAt,
            occurredDate: doc.occurredAt == null ? null : kgDateKey(doc.occurredAt!),
            confidence: KgConfidence.inferred,
            confidenceScore: 0.75,
            createdAt: now,
          ),
        );
      }
    }

    final edges = <String, KgEdge>{};
    for (final relation in relations) {
      final source = resolvedByName[normalizeKgName(relation.sourceName)];
      final target = resolvedByName[normalizeKgName(relation.targetName)];
      if (source == null || target == null || source.id == target.id) continue;
      final relationName = KgRelation.normalize(relation.relation);
      final edgeId = KgIds.edge(source.id, relationName, target.id);
      edges.putIfAbsent(
        edgeId,
        () => KgEdge(
          id: edgeId,
          sourceId: source.id,
          targetId: target.id,
          relation: relationName,
          confidence: KgConfidence.inferred,
          confidenceScore: relation.confidence,
          weight: 1,
          evidence: [
            KgEvidence(
              sourceType: doc.sourceType,
              sourceId: doc.sourceId,
              path: doc.path,
              snippet: relation.evidence,
              occurredDate: doc.occurredAt == null ? null : kgDateKey(doc.occurredAt!),
            ),
          ],
          firstSeenAt: now,
          lastSeenAt: now,
          updatedAt: now,
        ),
      );
    }

    return KgSemanticResult(
      nodes: nodes.values.toList(),
      edges: edges.values.toList(),
      mentions: mentions,
      summary: summary,
    );
  }

  List<String> _chunk(String text) {
    if (text.length <= maxChunkChars) return [text];
    final chunks = <String>[];
    for (var i = 0; i < text.length && chunks.length < maxChunks; i += maxChunkChars) {
      final end = (i + maxChunkChars).clamp(0, text.length);
      chunks.add(text.substring(i, end));
    }
    return chunks;
  }

  Map<String, _SemanticEntity> _validateEntities(dynamic rawEntities, String chunk) {
    final result = <String, _SemanticEntity>{};
    if (rawEntities is! List) return result;
    final chunkNorm = _evidenceNormalize(chunk);
    for (final raw in rawEntities) {
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString().trim();
      if (name.length < 2 || name.length > 40) continue;
      if (KgDictionaries.stopwords.contains(name)) continue;
      final aliases = <String>{
        for (final alias in (raw['aliases'] is List ? raw['aliases'] as List : const []))
          if (alias.toString().trim().length >= 2) alias.toString().trim(),
      };
      // 实体名或别名至少有一个能在原文里找到，防止模型把常识带进来
      final present = [name, ...aliases].any((candidate) => chunkNorm.contains(_evidenceNormalize(candidate)));
      if (!present) continue;
      final type = KgEntityType.normalize(raw['type']?.toString());
      final key = '$type|${normalizeKgName(name)}';
      result[key] = _SemanticEntity(name: name, type: type, aliases: aliases.toList());
    }
    return result;
  }

  List<_SemanticRelation> _validateRelations(
    dynamic rawRelations,
    String chunk,
    Map<String, _SemanticEntity> validEntities,
  ) {
    final result = <_SemanticRelation>[];
    if (rawRelations is! List) return result;
    final chunkNorm = _evidenceNormalize(chunk);
    for (final raw in rawRelations) {
      if (raw is! Map || result.length >= 40) break;
      final sourceName = (raw['source'] ?? '').toString().trim();
      final targetName = (raw['target'] ?? '').toString().trim();
      final evidence = (raw['evidence'] ?? '').toString().trim();
      if (sourceName.isEmpty || targetName.isEmpty || evidence.length < 2) continue;
      if (sourceName == targetName) continue;
      if (!validEntities.containsKey(normalizeKgName(sourceName)) ||
          !validEntities.containsKey(normalizeKgName(targetName))) {
        continue;
      }
      // 证据必须逐字出现在原文；模型改写/概括过的关系一律丢弃
      if (!chunkNorm.contains(_evidenceNormalize(evidence))) continue;
      final confidenceRaw = raw['confidence'];
      final confidence = confidenceRaw is num
          ? confidenceRaw.toDouble()
          : double.tryParse(confidenceRaw?.toString() ?? '') ?? 0.7;
      result.add(
        _SemanticRelation(
          sourceName: sourceName,
          targetName: targetName,
          relation: KgRelation.normalize(raw['relation']?.toString()),
          evidence: evidence,
          confidence: confidence.clamp(0.55, 0.95).toDouble(),
        ),
      );
    }
    return result;
  }

  Map<String, dynamic>? _parseJson(String content) {
    var text = content.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      text = text.replaceFirst(RegExp(r'\s*```$'), '');
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  String _evidenceNormalize(String text) {
    return text.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }
}

class _SemanticEntity {
  final String name;
  final String type;
  final List<String> aliases;
  final List<int> chunkIndexes = [];

  _SemanticEntity({required this.name, required this.type, required this.aliases});
}

class _SemanticRelation {
  final String sourceName;
  final String targetName;
  final String relation;
  final String evidence;
  final double confidence;

  const _SemanticRelation({
    required this.sourceName,
    required this.targetName,
    required this.relation,
    required this.evidence,
    required this.confidence,
  });
}
