import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

void main() {
  late Database db;
  late KnowledgeGraphRepository repo;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.overrideDatabasePath(inMemoryDatabasePath);
    db = await DatabaseHelper.instance.database;
    repo = KnowledgeGraphRepository();
  });

  setUp(() async {
    for (final table in const [
      'kg_nodes',
      'kg_aliases',
      'kg_edges',
      'kg_mentions',
      'kg_documents',
      'kg_insights',
      'kg_meta',
    ]) {
      await db.delete(table);
    }
  });

  KgNode node(
    String id, {
    String name = '测试实体',
    String type = KgEntityType.topic,
    String kind = KgNodeKind.entity,
    String? normalized,
    List<String> aliases = const [],
    int mentionCount = 0,
  }) {
    final now = DateTime(2026, 11, 10);
    return KgNode(
      id: id,
      kind: kind,
      type: type,
      name: name,
      normalizedName: normalized ?? name,
      aliases: aliases,
      mentionCount: mentionCount,
      createdAt: now,
      updatedAt: now,
    );
  }

  KgEdge edge(String sourceId, String targetId, {String relation = KgRelation.relatedTo, int weight = 1}) {
    final now = DateTime(2026, 11, 10);
    return KgEdge(
      id: 'edge-$sourceId-$targetId-$relation',
      sourceId: sourceId,
      targetId: targetId,
      relation: relation,
      confidence: KgConfidence.inferred,
      confidenceScore: 0.75,
      weight: weight.toDouble(),
      evidence: [
        const KgEvidence(
          sourceType: KgSourceType.timeline,
          sourceId: 'r1',
          path: '/timeline/2026-11-10.md',
          snippet: '原文',
          occurredDate: '2026-11-10',
        ),
      ],
      firstSeenAt: now,
      lastSeenAt: now,
      updatedAt: now,
    );
  }

  group('节点与别名', () {
    test('按 id/归一名/别名精确查找', () async {
      final item = node('e1', name: '咖啡', type: KgEntityType.drink, aliases: ['拿铁']);
      await repo.upsertNode(item);
      await repo.upsertAlias(entityId: 'e1', alias: '拿铁');

      expect((await repo.getNodeById('e1'))?.name, '咖啡');
      expect((await repo.findExactNode('咖啡', type: KgEntityType.drink))?.id, 'e1');
      expect((await repo.findExactNode('拿铁', type: KgEntityType.drink))?.id, 'e1');
      // 类型不同不能命中
      expect(await repo.findExactNode('咖啡', type: KgEntityType.place), isNull);
    });

    test('搜索按名称/别名召回并按提及次数排序', () async {
      await repo.upsertNode(node('e1', name: '咖啡', type: KgEntityType.drink, aliases: ['拿铁'], mentionCount: 2));
      await repo.upsertNode(node('e2', name: '咖啡店', type: KgEntityType.place, mentionCount: 10));

      final results = await repo.searchNodes('咖');
      expect(results.length, greaterThanOrEqualTo(2));
      expect(results.first.mentionCount, greaterThanOrEqualTo(2));
    });
  });

  group('边', () {
    test('同一条边重复写入时合并证据与权重', () async {
      await repo.upsertNode(node('a', name: 'A'));
      await repo.upsertNode(node('b', name: 'B'));
      await repo.upsertEdge(edge('a', 'b'));

      final second = edge('a', 'b').copyWith(
        confidence: KgConfidence.extracted,
        confidenceScore: 1.0,
        evidence: [
          const KgEvidence(
            sourceType: KgSourceType.note,
            sourceId: 'n1',
            path: '/notes/n1.md',
            snippet: '另一条证据',
            occurredDate: '2026-11-11',
          ),
        ],
      );
      await repo.upsertEdge(second);

      final edges = await repo.getEdgesForNode('a');
      expect(edges.length, 1);
      expect(edges.first.weight, 2);
      expect(edges.first.confidence, KgConfidence.extracted);
      expect(edges.first.evidence.length, 2);
    });

    test('按关系过滤邻居', () async {
      await repo.upsertNode(node('a', name: 'A'));
      await repo.upsertNode(node('b', name: 'B'));
      await repo.upsertNode(node('c', name: 'C'));
      await repo.upsertEdge(edge('a', 'b', relation: KgRelation.relatedTo));
      await repo.upsertEdge(edge('a', 'c', relation: KgRelation.worsens));

      final onlyWorsens = await repo.getEdgesForNode('a', relations: {KgRelation.worsens});
      expect(onlyWorsens.length, 1);
      expect(onlyWorsens.first.targetId, 'c');
    });
  });

  group('提及与删除源数据', () {
    test('同一节点同源的提及按唯一键去重', () async {
      final now = DateTime(2026, 11, 10);
      KgMention mention(String snippet) => KgMention(
        id: 'm1',
        nodeId: 'e1',
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        path: '/timeline/2026-11-10.md',
        field: 'tag:health.symptom',
        snippet: snippet,
        occurredDate: '2026-11-10',
        createdAt: now,
      );
      await repo.upsertMention(mention('头痛'));
      await repo.upsertMention(mention('头痛严重'));

      final list = await repo.getMentionsForNode('e1');
      expect(list.length, 1);
      expect(list.first.snippet, '头痛严重');
    });

    test('删除源记录时清掉提及、结构边与证据', () async {
      final now = DateTime(2026, 11, 10);
      await repo.upsertNode(node('source:timeline:r1', name: '记录', kind: KgNodeKind.source));
      await repo.upsertNode(node('a', name: 'A'));
      await repo.upsertNode(node('b', name: 'B'));
      await repo.upsertEdge(
        KgEdge(
          id: 'source-edge',
          sourceId: 'source:timeline:r1',
          targetId: 'a',
          relation: KgRelation.partOf,
          firstSeenAt: now,
          lastSeenAt: now,
          updatedAt: now,
        ),
      );
      await repo.upsertEdge(edge('a', 'b'));
      await repo.upsertMention(
        KgMention(
          id: 'm1',
          nodeId: 'a',
          sourceType: KgSourceType.timeline,
          sourceId: 'r1',
          path: '/timeline/2026-11-10.md',
          createdAt: now,
        ),
      );

      await repo.deleteSourceData(KgSourceType.timeline, 'r1');

      expect(await repo.getNodeById('source:timeline:r1'), isNull);
      expect(await repo.getMentionsForNode('a'), isEmpty);
      final aToB = await repo.getEdgesForNode('a');
      // a-b 边只有 r1 一条证据，证据被摘空后应删除
      expect(aToB, isEmpty);
    });
  });

  group('增量状态与洞察', () {
    test('文档状态按 source_type + source_id 读写', () async {
      await repo.upsertDocument(
        KgDocument(
          sourceType: KgSourceType.note,
          sourceId: 'n1',
          contentHash: 'hash1',
          updatedAt: DateTime(2026, 11, 10),
        ),
      );
      final doc = await repo.getDocument(KgSourceType.note, 'n1');
      expect(doc?.contentHash, 'hash1');
      expect((await repo.getDocumentsBySourceType(KgSourceType.note)).length, 1);
    });

    test('替换洞察不会让已忽略的条目复活', () async {
      final now = DateTime(2026, 11, 10);
      KgInsight insight(String id, String status) => KgInsight(
        id: id,
        kind: KgInsightKind.association,
        title: '标题$id',
        body: '正文',
        score: 1,
        support: 5,
        confidence: 0.6,
        lift: 1.8,
        status: status,
        createdAt: now,
        updatedAt: now,
      );
      await db.insert('kg_insights', insight('a', 'dismissed').toMap());
      await repo.replaceInsights([insight('a', 'new'), insight('b', 'new')]);

      final all = await repo.getInsights(limit: 10);
      final ids = {for (final item in all) item.id: item.status};
      expect(ids['a'], 'dismissed');
      expect(ids['b'], 'new');
    });
  });
}
