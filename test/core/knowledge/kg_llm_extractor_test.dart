import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_extractor.dart';
import 'package:qnote_flutter/core/knowledge/kg_llm_extractor.dart';
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
    for (final table in const ['kg_nodes', 'kg_aliases', 'kg_edges', 'kg_mentions']) {
      await db.delete(table);
    }
  });

  KgSourceDocument doc() {
    return KgSourceDocument(
      sourceType: KgSourceType.note,
      sourceId: 'n1',
      title: '最近的睡眠',
      body: '最近总是熬夜到一点，熬夜后第二天头痛得厉害，下午喝了咖啡也没有缓解，晚上也睡不好，白天没有精神。',
      occurredAt: DateTime(2026, 11, 10, 20),
      path: '/notes/健康/最近的睡眠.md',
    );
  }

  test('合法实体与关系入库，证据必须逐字命中', () async {
    final response = jsonEncode({
      'summary': '熬夜后容易头痛',
      'entities': [
        {
          'name': '熬夜',
          'type': 'habit',
          'aliases': ['晚睡'],
        },
        {
          'name': '头痛',
          'type': 'symptom',
          'aliases': ['头疼'],
        },
        {'name': '不存在', 'type': 'topic', 'aliases': []},
      ],
      'relations': [
        {'source': '熬夜', 'target': '头痛', 'relation': 'worsens', 'evidence': '熬夜后第二天头痛', 'confidence': 0.82},
        {'source': '熬夜', 'target': '头痛', 'relation': 'related_to', 'evidence': '模型编造的证据', 'confidence': 0.9},
      ],
    });

    final extractor = KgLlmExtractor(chatOverride: (_) async => response);
    final result = await extractor.extract(doc());
    expect(result, isNotNull);
    final names = result!.nodes.map((n) => n.name).toSet();
    expect(names, contains('熬夜'));
    expect(names, contains('头痛'));
    expect(names, isNot(contains('不存在')));
    expect(result.edges.length, 1);
    expect(result.edges.first.relation, KgRelation.worsens);
    expect(result.edges.first.confidence, KgConfidence.inferred);
    expect(result.edges.first.evidence.first.snippet, '熬夜后第二天头痛');
    expect(result.edges.first.evidence.first.path, '/notes/健康/最近的睡眠.md');
    expect(result.summary, '熬夜后容易头痛');
    expect(result.mentions, isNotEmpty);
  });

  test('中文类型/关系会归一到英文词表', () async {
    final response = jsonEncode({
      'summary': '',
      'entities': [
        {'name': '熬夜', 'type': '习惯', 'aliases': []},
        {'name': '头痛', 'type': '症状', 'aliases': []},
      ],
      'relations': [
        {'source': '熬夜', 'target': '头痛', 'relation': '加重', 'evidence': '熬夜后第二天头痛', 'confidence': 0.8},
      ],
    });

    final extractor = KgLlmExtractor(chatOverride: (_) async => response);
    final result = await extractor.extract(doc());
    expect(result, isNotNull);
    expect(result!.nodes.any((n) => n.name == '熬夜' && n.type == KgEntityType.habit), isTrue);
    expect(result.nodes.any((n) => n.name == '头痛' && n.type == KgEntityType.symptom), isTrue);
    expect(result.edges.single.relation, KgRelation.worsens);
  });

  test('非 JSON 响应返回空结果而不是抛错', () async {
    final extractor = KgLlmExtractor(chatOverride: (_) async => '我不知道');
    final result = await extractor.extract(doc());
    expect(result, isNotNull);
    expect(result!.nodes, isEmpty);
    expect(result.edges, isEmpty);
    expect(result.mentions, isEmpty);
  });

  test('实体不在原文时丢弃，避免模型带常识', () async {
    final response = jsonEncode({
      'summary': '',
      'entities': [
        {'name': '北京', 'type': 'place', 'aliases': []},
        {'name': '头痛', 'type': 'symptom', 'aliases': []},
      ],
      'relations': [
        {'source': '北京', 'target': '头痛', 'relation': 'related_to', 'evidence': '熬夜后第二天头痛', 'confidence': 0.8},
      ],
    });
    final extractor = KgLlmExtractor(chatOverride: (_) async => response);
    final result = await extractor.extract(doc());
    expect(result, isNotNull);
    expect(result!.nodes.map((n) => n.name), isNot(contains('北京')));
    expect(result.edges, isEmpty);
  });
}
