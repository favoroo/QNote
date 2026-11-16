import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

void main() {
  late Database db;
  late KnowledgeGraphRepository repo;
  final vfs = VirtualWorkspaceService.instance;

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

  Future<KgNode> seed() async {
    final now = DateTime(2026, 11, 10);
    final node = KgNode(
      id: 'entity-headache',
      kind: KgNodeKind.entity,
      type: KgEntityType.symptom,
      name: '头痛',
      normalizedName: '头痛',
      aliases: const ['头疼'],
      summary: '近期反复出现的头痛',
      mentionCount: 4,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertNode(node);
    await repo.upsertNode(
      KgNode(
        id: 'source:timeline:r1',
        kind: KgNodeKind.source,
        type: KgSourceType.timeline,
        name: '头痛记录',
        normalizedName: '头痛记录',
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        occurredDate: '2026-11-10',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertMention(
      KgMention(
        id: 'm1',
        nodeId: node.id,
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        path: '/timeline/2026-11-10.md',
        field: 'tag:health.symptom',
        snippet: 'symptom: [头痛]',
        occurredDate: '2026-11-10',
        createdAt: now,
      ),
    );
    return node;
  }

  test('根目录与 /graph 目录可见', () async {
    expect(await vfs.listDir('/'), contains('graph/'));
    final graphFiles = await vfs.listDir('/graph');
    expect(graphFiles, containsAll(['summary.json', 'insights.json', 'topics.json', 'entities/', 'days/']));
  });

  test('summary.json 输出图谱概览', () async {
    await seed();
    final content = await vfs.readFile('/graph/summary.json');
    expect(content, contains('entity_count'));
    expect(content, contains('头痛'));
  });

  test('实体详情含邻居与最近出现', () async {
    final node = await seed();
    final content = await vfs.readFile('/graph/entities/${node.id}.md');
    expect(content, contains('# 头痛'));
    expect(content, contains('症状'));
    expect(content, contains('/timeline/2026-11-10.md'));
  });

  test('单日关联 JSON 可读', () async {
    await seed();
    final content = await vfs.readFile('/graph/days/2026-11-10.json');
    expect(content, contains('headache'));
    expect(content, contains('/timeline/2026-11-10.md'));
  });

  test('grep scope=graph 能命中实体', () async {
    await seed();
    final hits = await vfs.grep('头痛', scope: 'graph');
    expect(hits, isNotEmpty);
    expect(hits.first['type'], 'graph');
    expect(hits.first['path'], '/graph/entities/entity-headache.md');
  });

  test('图谱路径拒绝写入/编辑/删除', () async {
    expect(() => vfs.writeFile('/graph/summary.json', 'x'), throwsA(isA<Exception>()));
    expect(() => vfs.editFile('/graph/summary.json', 'a', 'b'), throwsA(isA<Exception>()));
    expect(() => vfs.deleteFile('/graph/summary.json'), throwsA(isA<Exception>()));
  });
}
