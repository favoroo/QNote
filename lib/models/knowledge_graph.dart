import 'dart:convert';

/// 图谱节点类型（kind）常量。
///
/// - `entity`：从正文/字段抽取出的实体（人、食物、症状、主题等）；
/// - `state`：规则派生的状态（睡眠不足、久坐、低情绪等）；
/// - `source`：时间线记录/笔记/日记/待办/健康日等源数据；
/// - `day`：按日期聚合的锚点，方便跨来源遍历。
abstract final class KgNodeKind {
  static const String entity = 'entity';
  static const String state = 'state';
  static const String source = 'source';
  static const String day = 'day';

  static const Set<String> values = {entity, state, source, day};
}

/// 实体类型白名单。
///
/// 类型只用于展示、消歧与查询过滤，不追求本体论完备；LLM 返回白名单外的值
/// 会被归一到 `other`，避免脏类型扩散。
abstract final class KgEntityType {
  static const String person = 'person';
  static const String place = 'place';
  static const String organization = 'organization';
  static const String food = 'food';
  static const String drink = 'drink';
  static const String activity = 'activity';
  static const String sport = 'sport';
  static const String symptom = 'symptom';
  static const String medication = 'medication';
  static const String item = 'item';
  static const String topic = 'topic';
  static const String project = 'project';
  static const String emotion = 'emotion';
  static const String goal = 'goal';
  static const String habit = 'habit';
  static const String media = 'media';
  static const String other = 'other';

  static const Set<String> values = {
    person,
    place,
    organization,
    food,
    drink,
    activity,
    sport,
    symptom,
    medication,
    item,
    topic,
    project,
    emotion,
    goal,
    habit,
    media,
    other,
  };

  /// 中文展示名，供工具输出与 UI 使用
  static const Map<String, String> labels = {
    person: '人物',
    place: '地点',
    organization: '组织',
    food: '食物',
    drink: '饮品',
    activity: '活动',
    sport: '运动',
    symptom: '症状',
    medication: '用药',
    item: '物品',
    topic: '主题',
    project: '项目',
    emotion: '情绪',
    goal: '目标',
    habit: '习惯',
    media: '影音',
    other: '其他',
  };

  static String normalize(String? raw) {
    final text = (raw ?? '').trim();
    final byLabel = _labelToType[text];
    if (byLabel != null) return byLabel;
    final value = text.toLowerCase();
    return values.contains(value) ? value : other;
  }

  static final Map<String, String> _labelToType = {for (final entry in labels.entries) entry.value: entry.key};
}

/// 源数据类型（kg_documents.source_type）
abstract final class KgSourceType {
  static const String timeline = 'timeline';
  static const String note = 'note';
  static const String journal = 'journal';
  static const String todo = 'todo';
  static const String health = 'health';
  static const String memory = 'memory';

  static const Set<String> values = {timeline, note, journal, todo, health, memory};
}

/// 关系词表。LLM 只能从这里选，超出范围归一到 `related_to`。
abstract final class KgRelation {
  static const String relatedTo = 'related_to';
  static const String causedBy = 'caused_by';
  static const String improves = 'improves';
  static const String worsens = 'worsens';
  static const String partOf = 'part_of';
  static const String belongsTo = 'belongs_to';
  static const String supports = 'supports';
  static const String contradicts = 'contradicts';
  static const String precedes = 'precedes';
  static const String coOccursWith = 'co_occurs_with';

  static const Set<String> values = {
    relatedTo,
    causedBy,
    improves,
    worsens,
    partOf,
    belongsTo,
    supports,
    contradicts,
    precedes,
    coOccursWith,
  };

  /// 中文展示名
  static const Map<String, String> labels = {
    relatedTo: '相关',
    causedBy: '可能源于',
    improves: '改善',
    worsens: '加重',
    partOf: '属于',
    belongsTo: '归属',
    supports: '支持',
    contradicts: '矛盾',
    precedes: '先于',
    coOccursWith: '共同出现',
  };

  /// 结构关系不参与社区发现与洞察统计
  static const Set<String> structural = {partOf, belongsTo};

  static String normalize(String? raw) {
    final text = (raw ?? '').trim();
    final byLabel = _labelToRelation[text];
    if (byLabel != null) return byLabel;
    final value = text.toLowerCase();
    return values.contains(value) ? value : relatedTo;
  }

  static final Map<String, String> _labelToRelation = {for (final entry in labels.entries) entry.value: entry.key};
}

/// 证据置信度（对齐 graphify 的三档标注）
abstract final class KgConfidence {
  static const String extracted = 'EXTRACTED';
  static const String inferred = 'INFERRED';
  static const String ambiguous = 'AMBIGUOUS';

  static const Set<String> values = {extracted, inferred, ambiguous};

  static String normalize(String? raw) {
    final value = (raw ?? '').trim().toUpperCase();
    return values.contains(value) ? value : inferred;
  }
}

/// 洞察类型
abstract final class KgInsightKind {
  static const String association = 'association';
  static const String lagged = 'lagged';
  static const String bridge = 'bridge';
  static const String trend = 'trend';
}

/// 图谱边/洞察共用的证据条目。
///
/// 每条证据都必须能落到一条源记录与一个可读虚拟路径上；小Q 拿到后可直接
/// `read_file` 核实原文，而不是只相信图上的结论。
class KgEvidence {
  final String sourceType;
  final String sourceId;
  final String path;
  final String snippet;
  final String? occurredDate;

  const KgEvidence({
    required this.sourceType,
    required this.sourceId,
    required this.path,
    this.snippet = '',
    this.occurredDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'source_type': sourceType,
      'source_id': sourceId,
      'path': path,
      'snippet': snippet,
      'occurred_date': occurredDate,
    };
  }

  factory KgEvidence.fromMap(Map<String, dynamic> map) {
    return KgEvidence(
      sourceType: map['source_type']?.toString() ?? '',
      sourceId: map['source_id']?.toString() ?? '',
      path: map['path']?.toString() ?? '',
      snippet: map['snippet']?.toString() ?? '',
      occurredDate: map['occurred_date']?.toString(),
    );
  }

  static String encodeList(List<KgEvidence> evidence) {
    if (evidence.isEmpty) return '[]';
    return jsonEncode(evidence.map((e) => e.toMap()).toList());
  }

  static List<KgEvidence> decodeList(dynamic raw) {
    if (raw == null) return const [];
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => KgEvidence.fromMap(Map<String, dynamic>.from(e)))
          .where((e) => e.path.isNotEmpty || e.sourceId.isNotEmpty)
          .toList();
    } catch (_) {
      // 派生数据损坏时按无证据处理，不影响其余图谱读取
      return const [];
    }
  }
}

/// 图谱节点：实体、状态、源记录、日期。
class KgNode {
  final String id;
  final String kind;
  final String type;
  final String name;
  final String normalizedName;
  final List<String> aliases;
  final String summary;
  final String? sourceType;
  final String? sourceId;
  final DateTime? occurredAt;

  /// YYYY-MM-DD；按日聚合与洞察统计用，避免反复解析 occurredAt
  final String? occurredDate;
  final Map<String, dynamic> metadata;
  final int mentionCount;
  final double importance;
  final int? communityId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDeleted;

  const KgNode({
    required this.id,
    required this.kind,
    required this.type,
    required this.name,
    required this.normalizedName,
    this.aliases = const [],
    this.summary = '',
    this.sourceType,
    this.sourceId,
    this.occurredAt,
    this.occurredDate,
    this.metadata = const {},
    this.mentionCount = 0,
    this.importance = 0,
    this.communityId,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'kind': kind,
      'type': type,
      'name': name,
      'normalized_name': normalizedName,
      'aliases': jsonEncode(aliases),
      'summary': summary,
      'source_type': sourceType,
      'source_id': sourceId,
      'occurred_at': occurredAt?.toIso8601String(),
      'occurred_date': occurredDate,
      'metadata': jsonEncode(metadata),
      'mention_count': mentionCount,
      'importance': importance,
      'community_id': communityId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  factory KgNode.fromMap(Map<String, dynamic> map) {
    return KgNode(
      id: map['id'] as String,
      kind: map['kind'] as String? ?? KgNodeKind.entity,
      type: map['type'] as String? ?? KgEntityType.other,
      name: map['name'] as String? ?? '',
      normalizedName: map['normalized_name'] as String? ?? '',
      aliases: _decodeStringList(map['aliases']),
      summary: map['summary'] as String? ?? '',
      sourceType: map['source_type'] as String?,
      sourceId: map['source_id'] as String?,
      occurredAt: _parseDateTime(map['occurred_at']),
      occurredDate: map['occurred_date'] as String?,
      metadata: _decodeMap(map['metadata']),
      mentionCount: (map['mention_count'] as num?)?.toInt() ?? 0,
      importance: (map['importance'] as num?)?.toDouble() ?? 0,
      communityId: (map['community_id'] as num?)?.toInt(),
      createdAt: _parseDateTime(map['created_at']) ?? DateTime.now(),
      updatedAt: _parseDateTime(map['updated_at']) ?? DateTime.now(),
      isDeleted: (map['is_deleted'] as num?)?.toInt() == 1,
    );
  }

  KgNode copyWith({
    String? id,
    String? kind,
    String? type,
    String? name,
    String? normalizedName,
    List<String>? aliases,
    String? summary,
    String? sourceType,
    String? sourceId,
    DateTime? occurredAt,
    String? occurredDate,
    Map<String, dynamic>? metadata,
    int? mentionCount,
    double? importance,
    int? communityId,
    bool clearCommunityId = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
  }) {
    return KgNode(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      type: type ?? this.type,
      name: name ?? this.name,
      normalizedName: normalizedName ?? this.normalizedName,
      aliases: aliases ?? this.aliases,
      summary: summary ?? this.summary,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      occurredAt: occurredAt ?? this.occurredAt,
      occurredDate: occurredDate ?? this.occurredDate,
      metadata: metadata ?? this.metadata,
      mentionCount: mentionCount ?? this.mentionCount,
      importance: importance ?? this.importance,
      communityId: clearCommunityId ? null : (communityId ?? this.communityId),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}

/// 图谱边：实体/状态/源记录之间的关系，携带证据与置信度。
class KgEdge {
  final String id;
  final String sourceId;
  final String targetId;
  final String relation;
  final String confidence;
  final double confidenceScore;
  final double weight;
  final List<KgEvidence> evidence;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime updatedAt;
  final bool isDeleted;

  const KgEdge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.relation,
    this.confidence = KgConfidence.extracted,
    this.confidenceScore = 1.0,
    this.weight = 1.0,
    this.evidence = const [],
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'source_id': sourceId,
      'target_id': targetId,
      'relation': relation,
      'confidence': confidence,
      'confidence_score': confidenceScore,
      'weight': weight,
      'evidence': KgEvidence.encodeList(evidence),
      'first_seen_at': firstSeenAt.toIso8601String(),
      'last_seen_at': lastSeenAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  factory KgEdge.fromMap(Map<String, dynamic> map) {
    return KgEdge(
      id: map['id'] as String,
      sourceId: map['source_id'] as String? ?? '',
      targetId: map['target_id'] as String? ?? '',
      relation: KgRelation.normalize(map['relation']?.toString()),
      confidence: KgConfidence.normalize(map['confidence']?.toString()),
      confidenceScore: (map['confidence_score'] as num?)?.toDouble() ?? 1.0,
      weight: (map['weight'] as num?)?.toDouble() ?? 1.0,
      evidence: KgEvidence.decodeList(map['evidence']),
      firstSeenAt: _parseDateTime(map['first_seen_at']) ?? DateTime.now(),
      lastSeenAt: _parseDateTime(map['last_seen_at']) ?? DateTime.now(),
      updatedAt: _parseDateTime(map['updated_at']) ?? DateTime.now(),
      isDeleted: (map['is_deleted'] as num?)?.toInt() == 1,
    );
  }

  KgEdge copyWith({
    String? id,
    String? sourceId,
    String? targetId,
    String? relation,
    String? confidence,
    double? confidenceScore,
    double? weight,
    List<KgEvidence>? evidence,
    DateTime? firstSeenAt,
    DateTime? lastSeenAt,
    DateTime? updatedAt,
    bool? isDeleted,
  }) {
    return KgEdge(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      targetId: targetId ?? this.targetId,
      relation: relation ?? this.relation,
      confidence: confidence ?? this.confidence,
      confidenceScore: confidenceScore ?? this.confidenceScore,
      weight: weight ?? this.weight,
      evidence: evidence ?? this.evidence,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}

/// 实体提及：某节点出现在某条源记录的哪个字段/片段。
class KgMention {
  final String id;
  final String nodeId;
  final String sourceType;
  final String sourceId;
  final String path;
  final String field;
  final String snippet;
  final DateTime? occurredAt;
  final String? occurredDate;
  final String confidence;
  final double confidenceScore;
  final DateTime createdAt;

  const KgMention({
    required this.id,
    required this.nodeId,
    required this.sourceType,
    required this.sourceId,
    this.path = '',
    this.field = '',
    this.snippet = '',
    this.occurredAt,
    this.occurredDate,
    this.confidence = KgConfidence.extracted,
    this.confidenceScore = 1.0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'node_id': nodeId,
      'source_type': sourceType,
      'source_id': sourceId,
      'path': path,
      'field': field,
      'snippet': snippet,
      'occurred_at': occurredAt?.toIso8601String(),
      'occurred_date': occurredDate,
      'confidence': confidence,
      'confidence_score': confidenceScore,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory KgMention.fromMap(Map<String, dynamic> map) {
    return KgMention(
      id: map['id'] as String,
      nodeId: map['node_id'] as String? ?? '',
      sourceType: map['source_type'] as String? ?? '',
      sourceId: map['source_id'] as String? ?? '',
      path: map['path'] as String? ?? '',
      field: map['field'] as String? ?? '',
      snippet: map['snippet'] as String? ?? '',
      occurredAt: _parseDateTime(map['occurred_at']),
      occurredDate: map['occurred_date'] as String?,
      confidence: KgConfidence.normalize(map['confidence']?.toString()),
      confidenceScore: (map['confidence_score'] as num?)?.toDouble() ?? 1.0,
      createdAt: _parseDateTime(map['created_at']) ?? DateTime.now(),
    );
  }
}

/// 增量索引的每源文档状态。
class KgDocument {
  final String sourceType;
  final String sourceId;
  final String contentHash;
  final int extractorVersion;
  final String status;
  final int retryCount;
  final String? error;
  final DateTime? indexedAt;
  final DateTime updatedAt;

  const KgDocument({
    required this.sourceType,
    required this.sourceId,
    required this.contentHash,
    this.extractorVersion = 1,
    this.status = 'ok',
    this.retryCount = 0,
    this.error,
    this.indexedAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'source_type': sourceType,
      'source_id': sourceId,
      'content_hash': contentHash,
      'extractor_version': extractorVersion,
      'status': status,
      'retry_count': retryCount,
      'error': error,
      'indexed_at': indexedAt?.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory KgDocument.fromMap(Map<String, dynamic> map) {
    return KgDocument(
      sourceType: map['source_type'] as String? ?? '',
      sourceId: map['source_id'] as String? ?? '',
      contentHash: map['content_hash'] as String? ?? '',
      extractorVersion: (map['extractor_version'] as num?)?.toInt() ?? 1,
      status: map['status'] as String? ?? 'ok',
      retryCount: (map['retry_count'] as num?)?.toInt() ?? 0,
      error: map['error'] as String?,
      indexedAt: _parseDateTime(map['indexed_at']),
      updatedAt: _parseDateTime(map['updated_at']) ?? DateTime.now(),
    );
  }
}

/// 关联发现结果。
class KgInsight {
  final String id;
  final String kind;
  final String title;
  final String body;
  final double score;
  final int support;
  final double confidence;
  final double lift;
  final List<String> nodeIds;
  final List<KgEvidence> evidence;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const KgInsight({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.score = 0,
    this.support = 0,
    this.confidence = 0,
    this.lift = 0,
    this.nodeIds = const [],
    this.evidence = const [],
    this.periodStart,
    this.periodEnd,
    this.status = 'new',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'kind': kind,
      'title': title,
      'body': body,
      'score': score,
      'support': support,
      'confidence': confidence,
      'lift': lift,
      'node_ids': jsonEncode(nodeIds),
      'evidence': KgEvidence.encodeList(evidence),
      'period_start': periodStart?.toIso8601String(),
      'period_end': periodEnd?.toIso8601String(),
      'status': status,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory KgInsight.fromMap(Map<String, dynamic> map) {
    return KgInsight(
      id: map['id'] as String,
      kind: map['kind'] as String? ?? KgInsightKind.association,
      title: map['title'] as String? ?? '',
      body: map['body'] as String? ?? '',
      score: (map['score'] as num?)?.toDouble() ?? 0,
      support: (map['support'] as num?)?.toInt() ?? 0,
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
      lift: (map['lift'] as num?)?.toDouble() ?? 0,
      nodeIds: _decodeStringList(map['node_ids']),
      evidence: KgEvidence.decodeList(map['evidence']),
      periodStart: _parseDateTime(map['period_start']),
      periodEnd: _parseDateTime(map['period_end']),
      status: map['status'] as String? ?? 'new',
      createdAt: _parseDateTime(map['created_at']) ?? DateTime.now(),
      updatedAt: _parseDateTime(map['updated_at']) ?? DateTime.now(),
    );
  }

  KgInsight copyWith({String? status, DateTime? updatedAt}) {
    return KgInsight(
      id: id,
      kind: kind,
      title: title,
      body: body,
      score: score,
      support: support,
      confidence: confidence,
      lift: lift,
      nodeIds: nodeIds,
      evidence: evidence,
      periodStart: periodStart,
      periodEnd: periodEnd,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

List<String> _decodeStringList(dynamic raw) {
  if (raw == null) return const [];
  try {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! List) return const [];
    return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic> _decodeMap(dynamic raw) {
  if (raw == null) return const {};
  try {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return const {};
  } catch (_) {
    return const {};
  }
}

DateTime? _parseDateTime(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  return DateTime.tryParse(raw.toString());
}
