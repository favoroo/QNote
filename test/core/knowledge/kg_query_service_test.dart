import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_query_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

void main() {
  late Database db;
  late KnowledgeGraphRepository repo;
  late KnowledgeGraphQueryService query;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.overrideDatabasePath(inMemoryDatabasePath);
    db = await DatabaseHelper.instance.database;
    repo = KnowledgeGraphRepository();
    query = KnowledgeGraphQueryService.instance;
  });

  setUp(() async {
    for (final table in const ['kg_nodes', 'kg_aliases', 'kg_edges', 'kg_mentions', 'kg_insights']) {
      await db.delete(table);
    }
  });

  Future<KgNode> addNode(String id, String name, {String type = KgEntityType.topic}) async {
    final now = DateTime(2026, 11, 10);
    final node = KgNode(
      id: id,
      kind: KgNodeKind.entity,
      type: type,
      name: name,
      normalizedName: name,
      summary: '$name 的摘要',
      mentionCount: 3,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertNode(node);
    return node;
  }

  Future<void> addEdge(String a, String b, {String relation = KgRelation.relatedTo, double confidence = 0.8}) async {
    final now = DateTime(2026, 11, 10);
    await repo.upsertEdge(
      KgEdge(
        id: 'edge-$a-$b-$relation',
        sourceId: a,
        targetId: b,
        relation: relation,
        confidence: confidence >= 0.9 ? KgConfidence.extracted : KgConfidence.inferred,
        confidenceScore: confidence,
        weight: 2,
        evidence: [
          const KgEvidence(
            sourceType: KgSourceType.timeline,
            sourceId: 'r1',
            path: '/timeline/2026-11-10.md',
            snippet: '证据',
            occurredDate: '2026-11-10',
          ),
        ],
        firstSeenAt: now,
        lastSeenAt: now,
        updatedAt: now,
      ),
    );
  }

  test('节点解析：id、精确名、别名、歧义候选', () async {
    final a = await addNode('a', '头痛', type: KgEntityType.symptom);
    expect((await query.resolveNode('a')).node?.id, a.id);
    expect((await query.resolveNode('头痛')).node?.id, a.id);

    await repo.upsertAlias(entityId: a.id, alias: '头疼');
    expect((await query.resolveNode('头疼')).node?.id, a.id);

    await addNode('b', '头痛药', type: KgEntityType.medication);
    final ambiguous = await query.resolveNode('头');
    expect(ambiguous.isAmbiguous, isTrue);
    expect(ambiguous.candidates.length, greaterThanOrEqualTo(2));
  });

  test('邻居查询：深度 1 不越级，深度 2 展开二跳', () async {
    final a = await addNode('a', 'A');
    await addNode('b', 'B');
    await addNode('c', 'C');
    await addNode('d', 'D');
    await addEdge('a', 'b');
    await addEdge('a', 'c');
    await addEdge('b', 'd');

    final depth1 = await query.neighbors(a, depth: 1);
    final depth1Ids = depth1.nodes.map((n) => n.id).toSet();
    expect(depth1Ids, containsAll(['a', 'b', 'c']));
    expect(depth1Ids, isNot(contains('d')));

    final depth2 = await query.neighbors(a, depth: 2);
    expect(depth2.nodes.map((n) => n.id), contains('d'));
  });

  test('路径查询取最弱一跳置信度', () async {
    final a = await addNode('a', 'A');
    await addNode('b', 'B');
    final c = await addNode('c', 'C');
    await addEdge('a', 'b', confidence: 1.0);
    await addEdge('b', 'c', confidence: 0.6);

    final path = await query.path(a, c);
    expect(path.found, isTrue);
    expect(path.edges.length, 2);
    expect(path.confidence, closeTo(0.6, 0.0001));
  });

  test('时间线按日期分组输出', () async {
    final a = await addNode('a', '头痛', type: KgEntityType.symptom);
    final now = DateTime(2026, 11, 10);
    await repo.upsertMention(
      KgMention(
        id: 'm1',
        nodeId: a.id,
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        path: '/timeline/2026-11-10.md',
        snippet: '头痛',
        occurredDate: '2026-11-10',
        createdAt: now,
      ),
    );
    await repo.upsertMention(
      KgMention(
        id: 'm2',
        nodeId: a.id,
        sourceType: KgSourceType.timeline,
        sourceId: 'r2',
        path: '/timeline/2026-11-11.md',
        snippet: '又头痛',
        occurredDate: '2026-11-11',
        createdAt: now,
      ),
    );

    final mentions = await query.timeline(a);
    final text = query.formatTimeline(mentions, a.name);
    expect(text, contains('2026-11-10'));
    expect(text, contains('2026-11-11'));
    expect(text, contains('/timeline/2026-11-10.md'));
  });
}
