import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 会话置顶的落库语义测试。
///
/// 锁的是「置顶只是展示排序、不动数据时间归属」这条契约：历史抽屉按 `updatedAt`
/// 归档到「7 天内 / 30 天内 / 某年某月」，一旦置顶顺带刷了时间，三个月前的对话会
/// 整个搬进近组，且用户无法把它放回去。
void main() {
  late Database db;
  final repo = ConfigRepository.instance;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  String testId(String name) => 'cpt_${name}_$stamp';

  /// 刻意用一个**过去**的时间戳：只有这样「有没有被刷成 now」才可观察
  ChatSession buildSession(String id) {
    final createdAt = DateTime(2026, 3, 3, 8, 30);
    return ChatSession(
      id: id,
      title: '测试对话 $id',
      messages: [ChatMessage(role: 'user', content: '你好', timestamp: createdAt)],
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  Future<Map<String, Object?>?> rawRow(String id) async {
    final rows = await db.query(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> logsOf(String id) {
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
    await db.delete('chat_sessions', where: 'id LIKE ?', whereArgs: ['cpt_%']);
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id LIKE ?",
      whereArgs: ['cpt_%'],
    );
  });

  test('置顶只改 is_pinned，updated_at 逐字不变', () async {
    final id = testId('pin');
    await repo.insertChatSession(buildSession(id));
    final before = await rawRow(id);
    expect(before, isNotNull);

    await repo.setChatSessionPinned(id, true);

    final after = await rawRow(id);
    expect(after!['is_pinned'], 1);
    expect(after['updated_at'], before!['updated_at']);
    expect(after['created_at'], before['created_at']);
    expect(after['title'], before['title']);

    await repo.setChatSessionPinned(id, false);
    expect((await rawRow(id))!['is_pinned'], 0);
    expect((await rawRow(id))!['updated_at'], before['updated_at']);
  });

  test('置顶以 operation=update 落进 sync_log，且 data 保留原 updated_at', () async {
    final id = testId('sync');
    final session = buildSession(id);
    await repo.insertChatSession(session);
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id = ?",
      whereArgs: [id],
    );

    await repo.setChatSessionPinned(id, true);

    final logs = await logsOf(id);
    expect(logs.length, 1);
    expect(logs.first['operation'], 'update');
    final data = jsonDecode(logs.first['data'] as String) as Map<String, dynamic>;
    expect(data['is_pinned'], 1);
    expect(data['updated_at'], session.updatedAt.toIso8601String());
  });

  test('对不存在的 id 切换置顶是 no-op，不抛', () async {
    await repo.setChatSessionPinned(testId('missing'), true);
  });

  test('对照组：updateChatSession 确实会刷 updatedAt（所以置顶不能复用它）', () async {
    final id = testId('touch');
    await repo.insertChatSession(buildSession(id));
    final originalUpdatedAt = DateTime.parse(
      (await rawRow(id))!['updated_at'] as String,
    );

    final updated = await repo.updateChatSession(
      (await repo.getChatSession(id))!.copyWith(title: '改个名'),
    );

    expect(updated.title, '改个名');
    expect(updated.updatedAt.isAfter(originalUpdatedAt), isTrue);
  });

  test('is_pinned 在 toMap/fromMap 往返一致，缺键与 bool 写法都不抛', () {
    final session = buildSession(testId('map')).copyWith(isPinned: true);
    expect(ChatSession.fromMap(session.toMap()).isPinned, isTrue);
    // 迁移前的老行 / 旧版本备份：缺键按未置顶
    expect(ChatSession.fromMap(session.toMap()..remove('is_pinned')).isPinned, isFalse);
    // 对端 JSON 直接写 bool 的历史格式
    expect(
      ChatSession.fromMap(session.toMap()..['is_pinned'] = false).isPinned,
      isFalse,
    );
  });
}
