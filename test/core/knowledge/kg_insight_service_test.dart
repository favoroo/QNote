import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_insight_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
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

  Future<void> seedStrongAssociation() async {
    final now = DateTime.now();
    await repo.upsertNode(
      KgNode(
        id: 'state:late_sleep',
        kind: KgNodeKind.state,
        type: 'late_sleep',
        name: '熬夜',
        normalizedName: '熬夜',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertNode(
      KgNode(
        id: 'entity:headache',
        kind: KgNodeKind.entity,
        type: KgEntityType.symptom,
        name: '头痛',
        normalizedName: '头痛',
        createdAt: now,
        updatedAt: now,
      ),
    );
    // 无关的第三类实体用于补足「有记录的天数」：
    // 没有记录的日子不能当作「B 没出现」，否则基线会被大量空白天稀释
    await repo.upsertNode(
      KgNode(
        id: 'entity:walk',
        kind: KgNodeKind.entity,
        type: KgEntityType.activity,
        name: '散步',
        normalizedName: '散步',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 60));
    var seq = 0;
    Future<void> addMention(String nodeId, DateTime date) async {
      await repo.upsertMention(
        KgMention(
          id: 'm${seq++}',
          nodeId: nodeId,
          sourceType: KgSourceType.timeline,
          sourceId: 'r$seq',
          path: '/timeline/${kgDateKey(date)}.md',
          snippet: nodeId.contains('late')
              ? '凌晨 1 点才睡'
              : nodeId.contains('walk')
              ? '散步半小时'
              : '头痛',
          occurredDate: kgDateKey(date),
          confidence: KgConfidence.extracted,
          confidenceScore: 1.0,
          createdAt: now,
        ),
      );
    }

    for (var i = 0; i < 10; i++) {
      final date = start.add(Duration(days: i));
      await addMention('state:late_sleep', date);
      await addMention('entity:headache', date);
    }
    for (var i = 20; i < 23; i++) {
      await addMention('entity:headache', start.add(Duration(days: i)));
    }
    // 10..24 天都有「散步」，保证观测天数 ≥21；它与 A/B 没有稳定共现
    for (var i = 10; i <= 24; i++) {
      await addMention('entity:walk', start.add(Duration(days: i)));
    }
  }

  test('从提及中挖掘出熬夜与头痛的关联', () async {
    await seedStrongAssociation();
    final insights = await KnowledgeGraphInsightService.instance.rebuild();
    expect(insights, isNotEmpty);
    final target = insights.firstWhere((insight) => insight.title.contains('熬夜') && insight.title.contains('头痛'));
    expect(target.support, greaterThanOrEqualTo(4));
    expect(target.confidence, greaterThan(0.5));
    expect(target.evidence, isNotEmpty);
    expect(target.body, contains('相关性'));
    expect(target.evidence.first.path, startsWith('/timeline/'));
  });

  test('top 只返回 new 状态，dismiss 后不再出现', () async {
    await seedStrongAssociation();
    final insights = await KnowledgeGraphInsightService.instance.rebuild();
    final first = insights.first;

    await KnowledgeGraphInsightService.instance.dismiss(first.id);
    final top = await KnowledgeGraphInsightService.instance.top(limit: 10);
    expect(top.any((insight) => insight.id == first.id), isFalse);

    // 重算也不应让已忽略的条目复活
    final rebuilt = await KnowledgeGraphInsightService.instance.rebuild();
    expect(rebuilt.any((insight) => insight.id == first.id), isFalse);
  });

  test('数据不足 21 天时返回空且不报错', () async {
    final now = DateTime.now();
    await repo.upsertNode(
      KgNode(
        id: 'e1',
        kind: KgNodeKind.entity,
        type: KgEntityType.topic,
        name: '测试',
        normalizedName: '测试',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await repo.upsertMention(
      KgMention(
        id: 'm1',
        nodeId: 'e1',
        sourceType: KgSourceType.timeline,
        sourceId: 'r1',
        path: '/timeline/${kgDateKey(now)}.md',
        occurredDate: kgDateKey(now),
        createdAt: now,
      ),
    );

    final insights = await KnowledgeGraphInsightService.instance.rebuild();
    expect(insights, isEmpty);
  });
}
