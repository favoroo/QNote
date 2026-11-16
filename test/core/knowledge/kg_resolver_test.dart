import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_resolver.dart';
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

  test('同类型同名返回同一节点', () async {
    final resolver = KgResolver();
    final first = await resolver.resolveEntity(name: '头痛', type: KgEntityType.symptom);
    final second = await resolver.resolveEntity(name: '头 痛', type: KgEntityType.symptom);
    expect(second.id, first.id);
  });

  test('同名不同类型保留为两个节点', () async {
    final resolver = KgResolver();
    final food = await resolver.resolveEntity(name: '苹果', type: KgEntityType.food);
    final company = await resolver.resolveEntity(name: '苹果', type: KgEntityType.organization);
    expect(company.id, isNot(food.id));
  });

  test('别名可以命中既有实体', () async {
    final resolver = KgResolver();
    final first = await resolver.resolveEntity(name: '布洛芬', type: KgEntityType.medication, aliases: ['芬必得']);
    final byAlias = await resolver.resolveEntity(name: '芬必得', type: KgEntityType.medication);
    expect(byAlias.id, first.id);
  });

  test('状态节点使用确定性 id', () async {
    final resolver = KgResolver();
    final first = await resolver.resolveState(stateType: 'sleep_short', name: '睡眠不足');
    final second = await resolver.resolveState(stateType: 'sleep_short', name: '睡眠不足');
    expect(second.id, first.id);
    expect(first.kind, KgNodeKind.state);
  });

  test('日期节点幂等', () async {
    final resolver = KgResolver();
    final first = await resolver.ensureDayNode('2026-11-10');
    final second = await resolver.ensureDayNode('2026-11-10');
    expect(second.id, first.id);
    expect(first.kind, KgNodeKind.day);
  });
}
