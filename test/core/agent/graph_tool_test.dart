import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/tools/general/graph_tool.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

void main() {
  late Database db;
  late KnowledgeGraphRepository repo;
  final tool = GraphTool();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.overrideDatabasePath(inMemoryDatabasePath);
    db = await DatabaseHelper.instance.database;
    repo = KnowledgeGraphRepository();
  });

  setUp(() async {
    for (final table in const ['kg_nodes', 'kg_aliases', 'kg_edges', 'kg_mentions', 'kg_meta', 'diary_records']) {
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
      mentionCount: 2,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertNode(node);
    return node;
  }

  Future<void> addEdge(String a, String b, {String relation = KgRelation.relatedTo}) async {
    final now = DateTime(2026, 11, 10);
    await repo.upsertEdge(
      KgEdge(
        id: 'edge-$a-$b-$relation',
        sourceId: a,
        targetId: b,
        relation: relation,
        confidence: KgConfidence.inferred,
        confidenceScore: 0.75,
        weight: 2,
        evidence: [
          const KgEvidence(
            sourceType: KgSourceType.timeline,
            sourceId: 'r1',
            path: '/timeline/2026-11-10.md',
            snippet: '同一天出现',
            occurredDate: '2026-11-10',
          ),
        ],
        firstSeenAt: now,
        lastSeenAt: now,
        updatedAt: now,
      ),
    );
  }

  test('空图谱时引导回退 grep，不报错', () async {
    final result = await tool.execute({'op': 'search', 'query': '头痛'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('尚未建立'));
    expect(result.modelOutput, contains('grep'));
  });

  test('search 返回实体与 id', () async {
    await addNode('e1', '头痛', type: KgEntityType.symptom);
    final result = await tool.execute({'op': 'search', 'query': '头痛'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('头痛'));
    expect(result.modelOutput, contains('e1'));
  });

  test('neighbors 返回关联与证据路径', () async {
    final headache = await addNode('e1', '头痛', type: KgEntityType.symptom);
    final sleep = await addNode('s1', '睡眠不足', type: 'sleep_short');
    // 状态节点的 kind 不影响查询；这里用 entity 便于复用 helper
    expect(sleep.id, 's1');
    await addEdge(headache.id, sleep.id, relation: KgRelation.coOccursWith);

    final result = await tool.execute({'op': 'neighbors', 'node': '头痛'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('睡眠不足'));
    expect(result.modelOutput, contains('/timeline/2026-11-10.md'));
  });

  test('名称歧义时返回候选而不是猜', () async {
    await addNode('e1', '成都行程');
    await addNode('e2', '成都旅行');
    final result = await tool.execute({'op': 'neighbors', 'node': '成都'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('多个候选'));
    expect(result.modelOutput, contains('成都行程'));
    expect(result.modelOutput, contains('成都旅行'));
  });

  test('timeline 按日期返回提及', () async {
    final node = await addNode('e1', '头痛', type: KgEntityType.symptom);
    await repo.upsertMention(
      KgMention(
        id: 'm1',
        nodeId: node.id,
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        path: '/timeline/2026-11-10.md',
        snippet: '头痛',
        occurredDate: '2026-11-10',
        createdAt: DateTime(2026, 11, 10),
      ),
    );
    final result = await tool.execute({'op': 'timeline', 'node': '头痛'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('2026-11-10'));
    expect(result.modelOutput, contains('/timeline/2026-11-10.md'));
  });

  test('stats 返回概览', () async {
    await addNode('e1', '头痛', type: KgEntityType.symptom);
    final result = await tool.execute({'op': 'stats'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('实体'));
    expect(result.modelOutput, contains('头痛'));
  });

  test('图谱落后时提示待整理数量与更新入口', () async {
    await addNode('e1', '头痛', type: KgEntityType.symptom);
    await db.insert('kg_meta', {
      'key': 'last_scan_at',
      'value': DateTime(2020).toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    final now = DateTime.now();
    await DiaryRepository().insert(
      DiaryRecord(
        id: 'r1',
        title: '记录',
        time: now,
        content: '下午头痛',
        displayTag: '健康',
        tags: const ['健康'],
        mood: 2,
        tagEntries: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final result = await tool.execute({'op': 'search', 'query': '头痛'});
    expect(result.isError, isFalse);
    expect(result.modelOutput, contains('尚未整理'));
    expect(result.modelOutput, contains('更新图谱'));
  });
}
