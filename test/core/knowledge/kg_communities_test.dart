import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_communities.dart';
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
    for (final table in const ['kg_nodes', 'kg_aliases', 'kg_edges', 'kg_mentions', 'kg_meta']) {
      await db.delete(table);
    }
  });

  Future<void> addNode(String id, String name) async {
    final now = DateTime(2026, 11, 10);
    await repo.upsertNode(
      KgNode(
        id: id,
        kind: KgNodeKind.entity,
        type: KgEntityType.topic,
        name: name,
        normalizedName: name,
        mentionCount: 2,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> addMention(String nodeId, String name) async {
    final now = DateTime(2026, 11, 10);
    await repo.upsertMention(
      KgMention(
        id: 'm-$nodeId',
        nodeId: nodeId,
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        path: '/timeline/2026-11-10.md',
        field: 'tag:test',
        snippet: name,
        occurredDate: '2026-11-10',
        createdAt: now,
      ),
    );
  }

  test('连通实体归入同一社区，孤立节点不生成主题', () async {
    await addNode('a', '熬夜');
    await addNode('b', '头痛');
    await addNode('c', '咖啡');
    await addNode('lonely', '孤立主题');
    await addMention('a', '熬夜');
    await addMention('b', '头痛');
    await addMention('c', '咖啡');

    final topics = await KnowledgeGraphCommunityService.instance.rebuild();
    expect(topics, isNotEmpty);
    expect(topics.first['size'], 3);
    expect(topics.first['label'], contains('熬夜'));

    final a = await repo.getNodeById('a');
    final b = await repo.getNodeById('b');
    final lonely = await repo.getNodeById('lonely');
    expect(a?.communityId, isNotNull);
    expect(a?.communityId, b?.communityId);
    expect(lonely?.communityId, isNull);

    // 共现边由 mentions 重建：三节点两两组合 = 3 条
    final coOccurrence = await repo.getEdgesForNode('a', relations: {KgRelation.coOccursWith});
    expect(coOccurrence.length, 2);

    final read = await KnowledgeGraphCommunityService.instance.topics();
    expect(read.first['community_id'], a?.communityId);
    expect(read.first['top_entities'], isNotEmpty);
  });

  test('源记录删除后共现边与社区同步清理', () async {
    await addNode('a', '熬夜');
    await addNode('b', '头痛');
    await addMention('a', '熬夜');
    await addMention('b', '头痛');
    await KnowledgeGraphCommunityService.instance.rebuild();
    expect((await repo.getNodeById('a'))?.communityId, isNotNull);

    await repo.deleteSourceData(KgSourceType.timeline, 'r1');
    await KnowledgeGraphCommunityService.instance.rebuild();

    expect(await repo.getEdgesForNode('a', relations: {KgRelation.coOccursWith}), isEmpty);
    expect((await repo.getNodeById('a'))?.communityId, isNull);
  });
}
