import 'dart:math' as math;

import 'package:qnote_flutter/core/knowledge/kg_dictionaries.dart';
import 'package:qnote_flutter/core/knowledge/kg_resolver.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 规则抽取的输入：与具体 Repository 解耦，便于单测与后续接入更多来源。
class KgSourceDocument {
  final String sourceType;
  final String sourceId;
  final String title;
  final String body;
  final String analysis;
  final DateTime? occurredAt;
  final String path;
  final Map<String, dynamic> metadata;
  final List<KgSourceTag> tagEntries;
  final List<String> labelTags;
  final String? folderName;
  final int? mood;

  const KgSourceDocument({
    required this.sourceType,
    required this.sourceId,
    required this.title,
    this.body = '',
    this.analysis = '',
    this.occurredAt,
    required this.path,
    this.metadata = const {},
    this.tagEntries = const [],
    this.labelTags = const [],
    this.folderName,
    this.mood,
  });

  String get displayTitle {
    final value = title.trim();
    if (value.isNotEmpty) return value;
    if (occurredAt != null && sourceType == KgSourceType.journal) return kgDateKey(occurredAt!);
    return sourceType == KgSourceType.health ? (occurredAt == null ? '健康日' : kgDateKey(occurredAt!)) : '未命名记录';
  }
}

/// 时间线/健康标签的轻量结构，避免抽取器依赖 DiaryRecord。
class KgSourceTag {
  final String id;
  final String name;
  final Map<String, dynamic> fields;

  const KgSourceTag({required this.id, required this.name, this.fields = const {}});
}

/// 一次规则抽取的结果；索引器负责清理旧数据后整体写入。
class KgExtractionResult {
  final List<KgNode> nodes;
  final List<KgEdge> edges;
  final List<KgMention> mentions;
  final String summary;

  const KgExtractionResult({this.nodes = const [], this.edges = const [], this.mentions = const [], this.summary = ''});
}

/// 规则抽取器：结构化标签 + 词典 + wikilink + 标题 + 健康状态。
///
/// 设计原则：零 LLM、高精度、可解释。所有节点/提及都带来源路径；自由文本
/// 词典命中标为 `INFERRED`，结构化字段/wikilink/标题标为 `EXTRACTED`。
class KgExtractor {
  final KnowledgeGraphRepository _repo;
  final KgResolver _resolver;

  KgExtractor({KnowledgeGraphRepository? repository, KgResolver? resolver})
    : _repo = repository ?? KnowledgeGraphRepository(),
      _resolver = resolver ?? KgResolver(repository: repository);

  Future<KgExtractionResult> extract(KgSourceDocument doc) async {
    final now = DateTime.now();
    final dateKey = doc.occurredAt == null ? null : kgDateKey(doc.occurredAt!);
    final nodes = <String, KgNode>{};
    final edges = <KgEdge>[];
    final mentions = <KgMention>[];

    // 1. 源节点
    final sourceNode = await _upsertSourceNode(doc, now);
    nodes[sourceNode.id] = sourceNode;

    // 2. 日期锚点：跨来源遍历（时间线 ↔ 日记 ↔ 健康 ↔ 待办）靠它
    if (dateKey != null) {
      final dayNode = await _resolver.ensureDayNode(
        dateKey,
        metadata: {
          if (doc.mood != null) 'mood': doc.mood,
          if (doc.metadata['steps'] != null) 'steps': doc.metadata['steps'],
          if (doc.metadata['sleep_minutes'] != null) 'sleep_minutes': doc.metadata['sleep_minutes'],
        },
      );
      nodes[dayNode.id] = dayNode;
      edges.add(
        KgEdge(
          id: KgIds.edge(sourceNode.id, KgRelation.partOf, dayNode.id),
          sourceId: sourceNode.id,
          targetId: dayNode.id,
          relation: KgRelation.partOf,
          confidence: KgConfidence.extracted,
          confidenceScore: 1.0,
          evidence: [
            KgEvidence(
              sourceType: doc.sourceType,
              sourceId: doc.sourceId,
              path: doc.path,
              snippet: kgSnippet(doc.body.isNotEmpty ? doc.body : doc.displayTitle),
              occurredDate: dateKey,
            ),
          ],
          firstSeenAt: now,
          lastSeenAt: now,
          updatedAt: now,
        ),
      );
    }

    // 3. 收集实体候选
    final candidates = _collectCandidates(doc);

    // 4. 解析实体 + 写提及
    final resolved = <String, KgNode>{};
    for (final candidate in candidates) {
      final node = await _resolver.resolveEntity(
        name: candidate.name,
        type: candidate.type,
        aliases: candidate.aliases,
      );
      nodes[node.id] = node;
      resolved[node.id] = node;
      mentions.add(
        KgMention(
          id: KgIds.mention(node.id, doc.sourceType, doc.sourceId, candidate.field),
          nodeId: node.id,
          sourceType: doc.sourceType,
          sourceId: doc.sourceId,
          path: doc.path,
          field: candidate.field,
          snippet: candidate.snippet,
          occurredAt: doc.occurredAt,
          occurredDate: dateKey,
          confidence: candidate.confidence,
          confidenceScore: candidate.confidenceScore,
          createdAt: now,
        ),
      );
    }

    // 5. 规则状态（睡眠/步数/屏幕/情绪/运动）
    for (final state in _deriveStates(doc)) {
      final node = await _resolver.resolveState(stateType: state.type, name: state.name, summary: state.summary);
      nodes[node.id] = node;
      resolved[node.id] = node;
      mentions.add(
        KgMention(
          id: KgIds.mention(node.id, doc.sourceType, doc.sourceId, 'state'),
          nodeId: node.id,
          sourceType: doc.sourceType,
          sourceId: doc.sourceId,
          path: doc.path,
          field: 'state',
          snippet: state.snippet,
          occurredAt: doc.occurredAt,
          occurredDate: dateKey,
          confidence: KgConfidence.extracted,
          confidenceScore: 1.0,
          createdAt: now,
        ),
      );
    }

    // 6. 文档内共现边：让实体图一开始就可遍历；洞察服务会周期性全量重算
    edges.addAll(_buildCoOccurrenceEdges(doc, resolved.values.toList(), dateKey, now));

    return KgExtractionResult(
      nodes: nodes.values.toList(),
      edges: edges,
      mentions: mentions,
      summary: kgSnippet(doc.body.isNotEmpty ? doc.body : doc.displayTitle, maxLength: 160),
    );
  }

  Future<KgNode> _upsertSourceNode(KgSourceDocument doc, DateTime now) async {
    final id = KgIds.source(doc.sourceType, doc.sourceId);
    final existing = await _repo.getNodeById(id);
    final name = doc.displayTitle;
    final metadata = <String, dynamic>{
      ...doc.metadata,
      if (doc.folderName != null && doc.folderName!.trim().isNotEmpty) 'folder': doc.folderName!.trim(),
      if (doc.labelTags.isNotEmpty) 'tags': doc.labelTags,
      if (doc.mood != null) 'mood': doc.mood,
      if (doc.tagEntries.isNotEmpty)
        'tag_entries': [
          for (final tag in doc.tagEntries) {'id': tag.id, 'name': tag.name, 'fields': tag.fields},
        ],
    };
    final summary = kgSnippet(doc.body.isNotEmpty ? doc.body : doc.displayTitle, maxLength: 160);
    final node = KgNode(
      id: id,
      kind: KgNodeKind.source,
      type: doc.sourceType,
      name: name,
      normalizedName: normalizeKgName(name),
      aliases: existing?.aliases ?? const [],
      summary: summary,
      sourceType: doc.sourceType,
      sourceId: doc.sourceId,
      occurredAt: doc.occurredAt,
      occurredDate: doc.occurredAt == null ? null : kgDateKey(doc.occurredAt!),
      metadata: metadata,
      mentionCount: existing?.mentionCount ?? 0,
      importance: existing?.importance ?? 0,
      communityId: existing?.communityId,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _repo.upsertNode(node);
    return node;
  }

  List<_Candidate> _collectCandidates(KgSourceDocument doc) {
    final byKey = <String, _Candidate>{};

    void add(
      String name,
      String type,
      String field, {
      String snippet = '',
      String confidence = KgConfidence.extracted,
      double score = 1.0,
      Iterable<String> aliases = const [],
    }) {
      final clean = name.trim();
      if (clean.length < 2 || clean.length > 40) return;
      if (KgDictionaries.stopwords.contains(clean)) return;
      final normalized = normalizeKgName(clean);
      if (normalized.isEmpty) return;
      final normalizedType = KgEntityType.normalize(type);
      final key = '$normalizedType|$normalized';
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = _Candidate(
          name: clean,
          type: normalizedType,
          field: field,
          snippet: snippet.isEmpty ? clean : snippet,
          confidence: confidence,
          score: score,
          aliases: {
            for (final alias in aliases)
              if (normalizeKgName(alias).isNotEmpty) alias.trim(),
          }.toList(),
        );
        return;
      }
      existing.aliases.addAll(aliases.where((a) => normalizeKgName(a).isNotEmpty));
      existing.confidenceScore = math.max(existing.confidenceScore, score);
      // 结构化字段优先作为 evidence 字段，正文词典命中只做补充
      if (existing.confidence == KgConfidence.inferred && confidence == KgConfidence.extracted) {
        existing.field = field;
        existing.snippet = snippet.isEmpty ? clean : snippet;
        existing.confidence = confidence;
      }
    }

    // 3.1 结构化标签字段
    for (final tag in doc.tagEntries) {
      for (final entry in tag.fields.entries) {
        final fieldId = entry.key;
        if (KgDictionaries.isMetricField(fieldId)) continue;
        final values = KgDictionaries.fromTagField(tagId: tag.id, fieldId: fieldId, value: entry.value);
        for (final value in values) {
          add(
            value.name,
            value.type,
            'tag:${tag.id}.$fieldId',
            snippet: '$fieldId: ${entry.value}',
            confidence: KgConfidence.extracted,
            score: 1.0,
          );
        }
      }
    }

    // 3.2 标题：笔记/日记/待办标题就是主题；时间线标题只在非泛词时作为主题。
    // 日记标题就是日期，已有 day 节点，不再重复建一个日期主题。
    final title = doc.title.trim();
    final journalTitleIsDate = doc.sourceType == KgSourceType.journal && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(title);
    final titleIsTopic =
        !journalTitleIsDate &&
        (doc.sourceType == KgSourceType.note ||
            doc.sourceType == KgSourceType.journal ||
            doc.sourceType == KgSourceType.todo ||
            (doc.sourceType == KgSourceType.timeline &&
                title.length >= 3 &&
                !KgDictionaries.stopwords.contains(title)));
    if (titleIsTopic) {
      add(title, KgEntityType.topic, 'title', snippet: title, score: 1.0);
    }

    // 3.3 wikilink、标签、笔记本/分类
    for (final match in RegExp(r'\[\[([^\]|#]{1,40})(?:\|[^\]]+)?\]\]').allMatches(doc.body)) {
      final target = match.group(1)?.trim() ?? '';
      if (target.isNotEmpty) {
        add(target, KgEntityType.topic, 'wikilink', snippet: match.group(0)!, score: 1.0);
      }
    }
    for (final tag in doc.labelTags) {
      add(tag, KgEntityType.topic, 'tags', snippet: tag, score: 1.0);
    }
    final folderName = doc.folderName?.trim() ?? '';
    if (folderName.isNotEmpty && folderName != '今日' && folderName != '长期') {
      add(folderName, KgEntityType.topic, 'folder', snippet: folderName, score: 0.9);
    }

    // 3.4 Markdown 一二级标题（最多 5 个），避免长文把整篇目录都搬进图谱
    var headingCount = 0;
    for (final match in RegExp(r'^\s{0,3}#{1,2}\s+(.+)$', multiLine: true).allMatches(doc.body)) {
      if (headingCount >= 5) break;
      final heading = kgStripMarkdownPrefix(match.group(1) ?? '');
      if (heading.length >= 2 && heading.length <= 40 && !KgDictionaries.stopwords.contains(heading)) {
        add(heading, KgEntityType.topic, 'heading', snippet: heading, score: 0.85);
        headingCount++;
      }
    }

    // 3.5 自由文本词典：时间线把标题也算进去，笔记正文已经由标题主题覆盖
    final text = doc.sourceType == KgSourceType.timeline
        ? '${doc.title}\n${doc.body}\n${doc.analysis}'
        : '${doc.body}\n${doc.analysis}';
    for (final hit in KgDictionaries.matchText(text, limit: 30)) {
      add(
        hit.name,
        hit.type,
        hit.field,
        snippet: kgSnippet(text, query: hit.name),
        confidence: KgConfidence.inferred,
        score: 0.75,
      );
    }

    // 结构化候选优先，其次按置信度/出现顺序；上限 30 防止长笔记实体爆炸
    final candidates = byKey.values.toList()
      ..sort((a, b) {
        final byConfidence = b.confidenceScore.compareTo(a.confidenceScore);
        if (byConfidence != 0) return byConfidence;
        return a.name.compareTo(b.name);
      });
    return candidates.take(30).toList();
  }

  List<_StateHit> _deriveStates(KgSourceDocument doc) {
    final result = <_StateHit>[];
    final meta = doc.metadata;

    // 睡眠：优先用睡眠标签的小时数，健康日结用分钟数
    double? sleepHours;
    String? fallAsleepTime;
    for (final tag in doc.tagEntries) {
      if (tag.id != 'sleep' && tag.name != '睡眠') continue;
      final rawDuration = _firstValue(tag.fields, const ['duration', '时长', '时长 (小时)']);
      final parsed = _toDouble(rawDuration);
      if (parsed != null) sleepHours = parsed;
      final rawTime = _firstValue(tag.fields, const ['fallAsleepTime', '入睡时间']);
      if (rawTime != null) fallAsleepTime = rawTime.toString().trim();
    }
    final sleepMinutes = _toDouble(meta['sleep_minutes']);
    if (sleepHours == null && sleepMinutes != null && sleepMinutes > 0) {
      sleepHours = sleepMinutes / 60.0;
    }
    final sleepStart = meta['sleep_start_time']?.toString();
    if (fallAsleepTime == null && sleepStart != null) {
      final parsed = DateTime.tryParse(sleepStart);
      if (parsed != null) {
        fallAsleepTime =
            '${parsed.hour.toString().padLeft(2, '0')}:'
            '${parsed.minute.toString().padLeft(2, '0')}';
      }
    }
    if (sleepHours != null && sleepHours > 0 && sleepHours < 6) {
      result.add(
        _StateHit(
          type: 'sleep_short',
          name: '睡眠不足',
          summary: '单日睡眠少于 6 小时',
          snippet: '睡眠 ${sleepHours.toStringAsFixed(1)} 小时（<6 小时）',
        ),
      );
    }
    final lateMinutes = _lateSleepMinutes(fallAsleepTime);
    if (lateMinutes != null && lateMinutes <= 4 * 60) {
      // 00:30~04:00 视为熬夜；-1 天偏移的 "23:50" 不算
      result.add(_StateHit(type: 'late_sleep', name: '熬夜', summary: '入睡时间晚于 00:30', snippet: '入睡时间 $fallAsleepTime'));
    }

    final steps = _toDouble(meta['steps']);
    if (steps != null && steps > 0 && steps < 5000) {
      result.add(
        _StateHit(type: 'low_steps', name: '步数偏少', summary: '单日步数少于 5000', snippet: '步数 ${steps.toInt()}（<5000）'),
      );
    }
    final screenMs = _toDouble(meta['screen_time_ms']);
    if (screenMs != null && screenMs > 8 * 3600 * 1000) {
      result.add(
        _StateHit(
          type: 'high_screen',
          name: '屏幕时间偏长',
          summary: '单日屏幕使用超过 8 小时',
          snippet: '屏幕 ${(screenMs / 3600000).toStringAsFixed(1)} 小时（>8 小时）',
        ),
      );
    }
    final activeMinutes = _toDouble(meta['active_minutes']);
    if (activeMinutes != null && activeMinutes >= 0 && activeMinutes < 10) {
      result.add(
        _StateHit(
          type: 'no_exercise',
          name: '缺乏运动',
          summary: '单日活跃分钟数少于 10',
          snippet: '活跃 ${activeMinutes.toInt()} 分钟（<10）',
        ),
      );
    }

    final spend = _toDouble(meta['spend']);
    final spendP75 = _toDouble(meta['spend_p75']);
    if (spend != null && spend > 0 && spendP75 != null && spendP75 > 0 && spend > math.max(100.0, spendP75)) {
      result.add(
        _StateHit(
          type: 'high_spend',
          name: '消费偏高',
          summary: '单日支出高于近段 75 分位',
          snippet: '支出 ¥${spend.toStringAsFixed(0)}（75 分位 ¥${spendP75.toStringAsFixed(0)}）',
        ),
      );
    }

    final mood = doc.mood ?? _toInt(meta['mood']);
    if (mood != null && mood <= 2) {
      result.add(_StateHit(type: 'low_mood', name: '情绪偏低', summary: '当日心情评分 ≤2', snippet: '心情 $mood/5'));
    } else if (mood != null && mood >= 4) {
      result.add(_StateHit(type: 'high_mood', name: '情绪较好', summary: '当日心情评分 ≥4', snippet: '心情 $mood/5'));
    }

    return result;
  }

  List<KgEdge> _buildCoOccurrenceEdges(KgSourceDocument doc, List<KgNode> resolved, String? dateKey, DateTime now) {
    // 只取前 8 个高置信节点，避免一篇长笔记产生几十条两两组合
    final nodes = resolved.where((n) => n.kind == KgNodeKind.entity || n.kind == KgNodeKind.state).take(8).toList();
    if (nodes.length < 2) return const [];
    final edges = <KgEdge>[];
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = nodes[i];
        final b = nodes[j];
        final first = a.id.compareTo(b.id) <= 0 ? a : b;
        final second = a.id.compareTo(b.id) <= 0 ? b : a;
        edges.add(
          KgEdge(
            id: KgIds.edge(first.id, KgRelation.coOccursWith, second.id),
            sourceId: first.id,
            targetId: second.id,
            relation: KgRelation.coOccursWith,
            confidence: KgConfidence.inferred,
            confidenceScore: 0.6,
            weight: 1,
            evidence: [
              KgEvidence(
                sourceType: doc.sourceType,
                sourceId: doc.sourceId,
                path: doc.path,
                snippet: kgSnippet(doc.body.isNotEmpty ? doc.body : doc.displayTitle),
                occurredDate: dateKey,
              ),
            ],
            firstSeenAt: now,
            lastSeenAt: now,
            updatedAt: now,
          ),
        );
      }
    }
    return edges;
  }

  static dynamic _firstValue(Map<String, dynamic> fields, List<String> keys) {
    for (final key in keys) {
      final value = fields[key];
      if (value != null && value.toString().trim().isNotEmpty) return value;
    }
    return null;
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().trim());
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString().trim());
  }

  /// 返回「距午夜的分钟数」；23:00 这类前一天时间返回一个 >4*60 的值，不判熬夜
  static int? _lateSleepMinutes(String? time) {
    if (time == null || time.isEmpty) return null;
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(time);
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null) return null;
    return hour * 60 + minute;
  }
}

class _Candidate {
  final String name;
  final String type;
  final List<String> aliases;

  String field;
  String snippet;
  String confidence;
  double confidenceScore;

  _Candidate({
    required this.name,
    required this.type,
    required this.field,
    required this.snippet,
    required this.confidence,
    required double score,
    required this.aliases,
  }) : confidenceScore = score;
}

class _StateHit {
  final String type;
  final String name;
  final String summary;
  final String snippet;

  const _StateHit({required this.type, required this.name, required this.summary, required this.snippet});
}
