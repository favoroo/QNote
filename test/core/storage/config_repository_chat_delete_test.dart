import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 会话硬删除的行为契约测试。
///
/// 重点锁两件事：一是「删了就真没了」（旧实现只打 is_deleted 标记，空间永不释放），
/// 二是「删除必须以 operation=delete 落进 sync_log」（写成 update 会被打包成 upsert
/// 外发，导致已删对话在其它设备复活）。
void main() {
  late Database db;
  final repo = ConfigRepository.instance;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  String testId(String name) => 'cdt_${name}_$stamp';

  ChatSession buildSession(String id, {List<ChatMessage>? messages}) {
    return ChatSession(
      id: id,
      title: '测试对话 $id',
      messages: messages ??
          [
            ChatMessage(role: 'user', content: '你好'),
            ChatMessage(role: 'assistant', content: '在的'),
          ],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Future<List<Map<String, Object?>>> tombstonesOf(String id) {
    return db.query(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id = ?",
      whereArgs: [id],
    );
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete(
      'chat_sessions',
      where: 'id LIKE ?',
      whereArgs: ['cdt_%'],
    );
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id LIKE ?",
      whereArgs: ['cdt_%'],
    );
  });

  test('删除后行被物理移除，sync_log 只留一条 data 为空的 delete 墓碑', () async {
    final id = testId('single');
    await repo.insertChatSession(buildSession(id));
    // 清掉插入产生的日志，单独观察删除写了什么
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id = ?",
      whereArgs: [id],
    );

    final report = await repo.hardDeleteChatSession(id);

    expect(report.deletedSessions, 1);
    expect(report.messageCount, 2);
    expect(
      report.freedBytes,
      greaterThan(0),
      reason: 'freedBytes 里的消息体积取自 LENGTH(CAST(messages AS BLOB)) 别名，'
          '该表达式若没生效会静默为 0，占用统计就永远是空的',
    );
    expect(await repo.getChatSession(id), isNull);
    expect(
      await db.query('chat_sessions', where: 'id = ?', whereArgs: [id]),
      isEmpty,
      reason: '行必须真的消失，否则对话历史仍占着库空间',
    );

    final logs = await tombstonesOf(id);
    expect(logs.length, 1);
    expect(logs.first['operation'], 'delete');
    expect(
      logs.first['data'],
      isNull,
      reason: '墓碑绝不能携带整行内容，否则删除反而让 sync_log 膨胀',
    );
  });

  test('幂等：删除不存在的会话不报错，但仍写墓碑保证删除事件能继续转发', () async {
    final ghostId = testId('ghost');

    final report = await repo.hardDeleteChatSession(ghostId);

    expect(report.deletedSessions, 0);
    final logs = await tombstonesOf(ghostId);
    expect(logs.length, 1);
    expect(logs.first['operation'], 'delete');
  });

  test('批量删除：一个事务内每个会话各留一条墓碑', () async {
    final ids = [testId('b1'), testId('b2'), testId('b3')];
    for (final id in ids) {
      await repo.insertChatSession(buildSession(id));
    }
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id LIKE ?",
      whereArgs: ['cdt_%'],
    );

    final report = await repo.hardDeleteChatSessions(ids);

    expect(report.deletedSessions, 3);
    expect(await db.query('chat_sessions', where: 'id LIKE ?', whereArgs: ['cdt_%']), isEmpty);
    for (final id in ids) {
      final logs = await tombstonesOf(id);
      expect(logs.length, 1);
      expect(logs.first['operation'], 'delete');
    }
  });

  test('空 id 列表与空白 id 直接返回空报告', () async {
    expect((await repo.hardDeleteChatSessions([])).deletedSessions, 0);
    expect((await repo.hardDeleteChatSessions(['  '])).deletedSessions, 0);
    expect(
      await db.query(
        'sync_log',
        where: "table_name = 'chat_sessions' AND record_id LIKE ?",
        whereArgs: ['cdt_%'],
      ),
      isEmpty,
    );
  });

  test('删除事件打包成 deletes，不再以 upsert 形式外发', () async {
    final id = testId('delta');
    await repo.insertChatSession(buildSession(id));
    await repo.hardDeleteChatSession(id);

    final delta = await SyncLogRepository.instance.buildDeltaJson();
    final changes = delta['changes'] as Map<String, dynamic>;
    final chatChanges = changes['chat_sessions'] as Map<String, dynamic>;
    final deletes = (chatChanges['deletes'] as List).cast<String>();
    final upserts = (chatChanges['upserts'] as List)
        .cast<Map<String, dynamic>>()
        .where((row) => row['id'] == id)
        .toList();

    expect(deletes, contains(id));
    expect(
      upserts,
      isEmpty,
      reason: '一旦以 upsert 外发，对端就会把这条已删对话整条写回来',
    );
  });

  test('回收旧版软删除墓碑：is_deleted=1 的行可被清掉并转为 delete', () async {
    final tombstoneId = testId('tomb');
    final map = buildSession(tombstoneId).toMap();
    map['is_deleted'] = 1;
    await db.insert('chat_sessions', map);
    expect(await repo.getChatSession(tombstoneId), isNotNull);

    final report = await repo.purgeTombstonedChatSessions();

    expect(report.deletedSessions, greaterThanOrEqualTo(1));
    expect(await repo.getChatSession(tombstoneId), isNull);
    final logs = await tombstonesOf(tombstoneId);
    expect(logs.last['operation'], 'delete');
  });

  test('删除会话不改动笔记/日记/待办等业务数据', () async {
    final now = DateTime.now().toIso8601String();
    const noteId = 'cdt_note';
    const diaryId = 'cdt_diary';
    const todoId = 'cdt_todo';
    await db.delete('notes', where: 'id LIKE ?', whereArgs: ['cdt_%']);
    await db.delete('diary_records', where: 'id LIKE ?', whereArgs: ['cdt_%']);
    await db.delete('todos', where: 'id LIKE ?', whereArgs: ['cdt_%']);
    await db.insert('notes', {
      'id': noteId,
      'title': '小Q写的笔记',
      'content': '正文',
      'images': jsonEncode(['/x/images/ai/keep.png']),
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('diary_records', {
      'id': diaryId,
      'title': '小Q记的日记',
      'content': '正文',
      'photos': jsonEncode(['/x/images/ai/keep.png']),
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('todos', {
      'id': todoId,
      'title': '小Q建的待办',
      'created_at': now,
      'updated_at': now,
    });

    final sessionId = testId('cascade');
    await repo.insertChatSession(
      buildSession(
        sessionId,
        messages: [
          ChatMessage(role: 'user', content: '帮我记下来'),
          ChatMessage(
            role: 'tool',
            content: '已创建笔记',
            toolName: 'write_file',
            uiDetails: {
              'paths': ['/notes/小Q写的笔记.md'],
            },
          ),
        ],
      ),
    );

    await repo.hardDeleteChatSession(sessionId);

    expect(await repo.getChatSession(sessionId), isNull);
    expect(
      await db.query('notes', where: 'id = ?', whereArgs: [noteId]),
      hasLength(1),
      reason: '删除对话绝不能级联删掉小Q写出的笔记',
    );
    expect(
      await db.query('diary_records', where: 'id = ?', whereArgs: [diaryId]),
      hasLength(1),
    );
    expect(
      await db.query('todos', where: 'id = ?', whereArgs: [todoId]),
      hasLength(1),
    );

    await db.delete('notes', where: 'id = ?', whereArgs: [noteId]);
    await db.delete('diary_records', where: 'id = ?', whereArgs: [diaryId]);
    await db.delete('todos', where: 'id = ?', whereArgs: [todoId]);
  });

  test('占用估算能读出活跃与待回收体积', () async {
    final activeId = testId('active');
    await repo.insertChatSession(buildSession(activeId));

    var usage = await repo.estimateChatStorageUsage();
    expect(usage.activeSessions, greaterThanOrEqualTo(1));
    expect(
      usage.activeMessagesBytes,
      greaterThan(0),
      reason: 'LENGTH 必须按 BLOB 取字节，按字符计会把中文低估 2~3 倍',
    );

    final tombstoneId = testId('estimateTomb');
    final map = buildSession(tombstoneId).toMap();
    map['is_deleted'] = 1;
    await db.insert('chat_sessions', map);
    usage = await repo.estimateChatStorageUsage();
    expect(usage.tombstonedSessions, greaterThanOrEqualTo(1));
    expect(usage.reclaimableBytes, greaterThan(0));

    await repo.hardDeleteChatSessions([activeId, tombstoneId]);
  });
}
