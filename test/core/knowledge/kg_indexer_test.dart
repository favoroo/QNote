import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/knowledge/kg_indexer.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/models/todo.dart';

void main() {
  late Database db;
  late DiaryRepository diaryRepo;
  late NoteRepository noteRepo;
  late TodoRepository todoRepo;
  late KnowledgeGraphRepository graphRepo;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.overrideDatabasePath(inMemoryDatabasePath);
    db = await DatabaseHelper.instance.database;
    diaryRepo = DiaryRepository();
    noteRepo = NoteRepository();
    todoRepo = TodoRepository();
    graphRepo = KnowledgeGraphRepository();
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
      'diary_records',
      'notes',
      'todos',
    ]) {
      await db.delete(table);
    }
  });

  Future<DiaryRecord> seedDiary() async {
    final now = DateTime.now();
    final record = DiaryRecord(
      id: 'r1',
      title: '午饭和头痛',
      time: now,
      content: '中午吃了米饭，下午头痛得厉害。',
      displayTag: '健康',
      tags: const ['健康'],
      mood: 2,
      tagEntries: [
        TagEntry(id: 'diet', name: '饮食', fields: {'rating': '一般'}),
        TagEntry(
          id: 'health',
          name: '健康',
          fields: {
            'symptom': ['头痛'],
          },
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
    await diaryRepo.insert(record);
    return record;
  }

  test('全量索引把日记/笔记/待办写入图谱', () async {
    await seedDiary();
    final now = DateTime.now();
    await noteRepo.insert(
      Note(id: 'n1', title: '旅行计划', content: '准备去成都，顺便喝咖啡，看看[[宽窄巷子]]。', tags: '旅行', createdAt: now, updatedAt: now),
    );
    await todoRepo.insert(Todo(id: 't1', title: '订机票', description: '去成都出差', createdAt: now, updatedAt: now));

    final report = await KnowledgeGraphIndexer.instance.run(forceFull: true);
    expect(report.updated, greaterThanOrEqualTo(3));
    expect(report.failed, 0);

    final stats = await graphRepo.stats();
    expect((stats['entity_count'] as int), greaterThan(0));
    expect((stats['document_count'] as int), greaterThanOrEqualTo(3));

    final docs = await graphRepo.getDocumentsBySourceType(KgSourceType.timeline);
    expect(docs.any((d) => d.sourceId == 'r1' && d.status == 'ok'), isTrue);

    final headache = (await graphRepo.searchNodes('头痛')).firstWhere((n) => n.name == '头痛');
    final mentions = await graphRepo.getMentionsForNode(headache.id);
    expect(mentions, isNotEmpty);
    expect(mentions.first.path, startsWith('/timeline/'));

    final noteMentions = await graphRepo.getMentionsForSource(KgSourceType.note, 'n1');
    expect(noteMentions, isNotEmpty);
  });

  test('内容 hash 未变化时重复索引不重复处理', () async {
    await seedDiary();
    final first = await KnowledgeGraphIndexer.instance.run(forceFull: true);
    expect(first.updated, greaterThan(0));

    final second = await KnowledgeGraphIndexer.instance.run(forceFull: true);
    expect(second.updated, 0);
    expect(second.failed, 0);
  });

  test('记录编辑后旧提及被清理，新内容重新抽取', () async {
    final record = await seedDiary();
    await KnowledgeGraphIndexer.instance.run(forceFull: true);

    final headache = (await graphRepo.searchNodes('头痛')).firstWhere((n) => n.name == '头痛');
    expect(await graphRepo.getMentionsForNode(headache.id), isNotEmpty);

    final updated = record.copyWith(
      title: '跑步记录',
      content: '今天跑步五公里，状态不错，没有头痛。',
      tagEntries: [
        TagEntry(id: 'activity', name: '活动', fields: {'type': '运动'}),
      ],
      tags: const ['活动'],
      displayTag: '活动',
      mood: 4,
    );
    await diaryRepo.update(updated);
    await KnowledgeGraphIndexer.instance.run(forceFull: true);

    final mentions = await graphRepo.getMentionsForSource(KgSourceType.timeline, 'r1');
    expect(mentions.any((m) => m.nodeId == headache.id), isFalse);
    expect(mentions.any((m) => m.field.contains('activity')), isTrue);
  });

  test('删除源记录后对账会清掉图谱数据', () async {
    await seedDiary();
    await KnowledgeGraphIndexer.instance.run(forceFull: true);
    expect(await graphRepo.getDocument(KgSourceType.timeline, 'r1'), isNotNull);

    await diaryRepo.hardDelete('r1');
    // 手动更新每次都会对账，不需要再拨 last_reconcile_at
    final report = await KnowledgeGraphIndexer.instance.run(forceFull: true);

    expect(report.removed, greaterThanOrEqualTo(1));
    expect(await graphRepo.getDocument(KgSourceType.timeline, 'r1'), isNull);
    expect(await graphRepo.getSourceNode(KgSourceType.timeline, 'r1'), isNull);
    expect(await graphRepo.getMentionsForSource(KgSourceType.timeline, 'r1'), isEmpty);
  });

  test('手动更新会报告规则阶段进度，结束后清空进度', () async {
    await seedDiary();
    final phases = <KgRunPhase>[];
    void listener() {
      final value = KnowledgeGraphIndexer.instance.progress.value;
      if (value != null) phases.add(value.phase);
    }

    KnowledgeGraphIndexer.instance.progress.addListener(listener);
    final report = await KnowledgeGraphIndexer.instance.run(forceFull: true);
    KnowledgeGraphIndexer.instance.progress.removeListener(listener);

    expect(report.updated, greaterThan(0));
    expect(phases, contains(KgRunPhase.collecting));
    expect(phases, contains(KgRunPhase.rules));
    expect(KnowledgeGraphIndexer.instance.progress.value, isNull);
  });

  test('状态里能看到待整理数量与源数据标记', () async {
    await seedDiary();
    await KnowledgeGraphIndexer.instance.run(forceFull: true);

    var status = await KnowledgeGraphIndexer.instance.status();
    expect(status['pending_rule_count'], 0);
    expect(status['has_source_data'], isTrue);

    final record = await diaryRepo.getById('r1');
    expect(record, isNotNull);
    await diaryRepo.update(record!.copyWith(content: '${record.content}\n补一条记录'));

    status = await KnowledgeGraphIndexer.instance.status();
    expect(status['pending_rule_count'], greaterThan(0));
  });

  test('连续触发只执行一个更新任务', () async {
    await seedDiary();
    await KnowledgeGraphIndexer.instance.run(forceFull: true);
    final baseline = await KnowledgeGraphIndexer.instance.run(forceFull: true);
    expect(baseline.updated, 0);

    final record = await diaryRepo.getById('r1');
    await diaryRepo.update(record!.copyWith(content: '${record.content}\n新增一条'));

    final first = KnowledgeGraphIndexer.instance.run(forceFull: true);
    final second = KnowledgeGraphIndexer.instance.run(forceFull: true);
    final reports = await Future.wait([first, second]);

    expect(reports.first.updated, greaterThan(0));
    // 第二次调用被运行位挡住，返回的是开跑前的上一份报告
    expect(reports.last.updated, baseline.updated);
    expect(KnowledgeGraphIndexer.instance.progress.value, isNull);
  });
}
