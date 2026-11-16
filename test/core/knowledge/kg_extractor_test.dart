import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_extractor.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

void main() {
  late Database db;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.overrideDatabasePath(inMemoryDatabasePath);
    db = await DatabaseHelper.instance.database;
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

  KgSourceDocument timelineDoc({String id = 'r1', String body = '中午吃了米饭和香菇滑鸡，下午头痛得厉害，吃了布洛芬。', int mood = 2}) {
    return KgSourceDocument(
      sourceType: KgSourceType.timeline,
      sourceId: id,
      title: '午饭和头痛',
      body: body,
      occurredAt: DateTime(2026, 11, 10, 12, 30),
      path: '/timeline/2026-11-10.md',
      mood: mood,
      tagEntries: const [
        KgSourceTag(id: 'diet', name: '饮食', fields: {'rating': '一般', 'calories': 600}),
        KgSourceTag(
          id: 'health',
          name: '健康',
          fields: {
            'symptom': ['头痛'],
            'severity': '严重',
            'medication': '布洛芬',
          },
        ),
      ],
    );
  }

  test('时间线记录抽取出源/日期/实体/提及与状态', () async {
    final extractor = KgExtractor();
    final result = await extractor.extract(timelineDoc());

    final names = result.nodes.map((n) => n.name).toSet();
    expect(names, contains('头痛'));
    expect(names, contains('布洛芬'));
    expect(names, contains('米饭'));
    expect(names, contains('情绪偏低'));
    expect(result.nodes.any((n) => n.kind == KgNodeKind.source), isTrue);
    expect(result.nodes.any((n) => n.kind == KgNodeKind.day), isTrue);

    final headache = result.nodes.firstWhere((n) => n.name == '头痛');
    final headacheMentions = result.mentions.where((m) => m.nodeId == headache.id).toList();
    expect(headacheMentions, isNotEmpty);
    expect(
      headacheMentions.any((m) => m.field == 'tag:health.symptom' && m.confidence == KgConfidence.extracted),
      isTrue,
    );
    expect(headacheMentions.first.path, '/timeline/2026-11-10.md');
    expect(headacheMentions.first.occurredDate, '2026-11-10');

    // 源→日期结构边必须存在，跨来源遍历靠它
    expect(result.edges.any((e) => e.relation == KgRelation.partOf), isTrue);
    // 文档内共现边让实体图可遍历
    expect(result.edges.any((e) => e.relation == KgRelation.coOccursWith), isTrue);
  });

  test('同一实体重复索引复用节点，不会每次新建', () async {
    final extractor = KgExtractor();
    final first = await extractor.extract(timelineDoc(id: 'r1'));
    final firstHeadache = first.nodes.firstWhere((n) => n.name == '头痛');

    final second = await extractor.extract(timelineDoc(id: 'r2'));
    final secondHeadache = second.nodes.firstWhere((n) => n.name == '头痛');

    expect(secondHeadache.id, firstHeadache.id);
  });

  test('同名不同类型保留为两个节点', () async {
    final extractor = KgExtractor();
    final result = await extractor.extract(
      KgSourceDocument(
        sourceType: KgSourceType.timeline,
        sourceId: 'r3',
        title: '苹果发布会',
        body: '今天吃了苹果，又看了苹果发布会。',
        occurredAt: DateTime(2026, 11, 11, 10),
        path: '/timeline/2026-11-11.md',
        tagEntries: const [
          KgSourceTag(id: 'diet', name: '饮食', fields: {'item': '苹果'}),
        ],
        // 标签里的「苹果」是主题，与饮食字段里的「苹果（食物）」同名不同型
        labelTags: const ['苹果'],
      ),
    );

    final food = result.nodes.where((n) => n.name == '苹果' && n.type == KgEntityType.food).toList();
    final topic = result.nodes.where((n) => n.name == '苹果' && n.type == KgEntityType.topic).toList();
    expect(food.length, 1);
    expect(topic.length, 1);
    expect(food.first.id, isNot(topic.first.id));
  });

  test('睡眠标签派生睡眠不足与熬夜状态', () async {
    final extractor = KgExtractor();
    final result = await extractor.extract(
      KgSourceDocument(
        sourceType: KgSourceType.timeline,
        sourceId: 'r4',
        title: '睡眠',
        occurredAt: DateTime(2026, 11, 12, 7),
        path: '/timeline/2026-11-12.md',
        tagEntries: const [
          KgSourceTag(id: 'sleep', name: '睡眠', fields: {'duration': 5.2, 'fallAsleepTime': '01:20', 'quality': '一般'}),
        ],
      ),
    );

    final stateNames = result.nodes.where((n) => n.kind == KgNodeKind.state).map((n) => n.name).toSet();
    expect(stateNames, contains('睡眠不足'));
    expect(stateNames, contains('熬夜'));
  });

  test('健康日支出高于 75 分位时派生消费偏高状态', () async {
    final extractor = KgExtractor();
    final result = await extractor.extract(
      KgSourceDocument(
        sourceType: KgSourceType.health,
        sourceId: '2026-11-13',
        title: '2026-11-13',
        occurredAt: DateTime(2026, 11, 13),
        path: '/health/2026-11-13.json',
        metadata: const {'spend': 500.0, 'spend_p75': 200.0},
      ),
    );

    final stateNames = result.nodes.where((n) => n.kind == KgNodeKind.state).map((n) => n.name).toSet();
    expect(stateNames, contains('消费偏高'));
  });

  test('笔记标题、标签、wikilink 与标题层级成为主题实体', () async {
    final extractor = KgExtractor();
    final result = await extractor.extract(
      KgSourceDocument(
        sourceType: KgSourceType.note,
        sourceId: 'n1',
        title: '旅行计划',
        body: '# 成都行程\n\n准备去[[宽窄巷子]]，顺便喝咖啡。\n## 预算',
        occurredAt: DateTime(2026, 11, 13, 20),
        path: '/notes/旅行/旅行计划.md',
        labelTags: const ['旅行', '成都'],
        folderName: '旅行',
      ),
    );

    final names = result.nodes.map((n) => n.name).toSet();
    expect(names, contains('旅行计划'));
    expect(names, contains('成都行程'));
    expect(names, contains('宽窄巷子'));
    expect(names, contains('旅行'));
    expect(names, contains('成都'));
    expect(names, contains('咖啡'));
  });

  test('日记日期标题不会重复建一个日期主题节点', () async {
    final extractor = KgExtractor();
    final result = await extractor.extract(
      KgSourceDocument(
        sourceType: KgSourceType.journal,
        sourceId: 'journal_note_2026-11-10',
        title: '2026-11-10',
        body: '今天状态一般，晚上早点睡。',
        occurredAt: DateTime(2026, 11, 10),
        path: '/journal/2026-11-10.md',
      ),
    );

    final dateTopics = result.nodes.where((n) => n.kind == KgNodeKind.entity && n.name == '2026-11-10');
    expect(dateTopics, isEmpty);
    expect(result.nodes.any((n) => n.kind == KgNodeKind.day && n.name == '2026-11-10'), isTrue);
  });
}
