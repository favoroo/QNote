import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 对端删除事件在本端的落地行为。
///
/// 多端复活的根因就在这里：远端 `deletes` 若只打软删标记、或对端推来的墓碑被当普通
/// 会话插回来，用户在 A 机删掉的对话就会在 B 机复活并继续占着空间。
void main() {
  late Database db;
  final repo = ConfigRepository.instance;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  String testId(String name) => 'xdel_${name}_$stamp';

  Map<String, dynamic> sessionMap(String id, {int isDeleted = 0}) {
    return ChatSession(
      id: id,
      title: '远端来的对话',
      messages: [ChatMessage(role: 'user', content: 'hi')],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      isDeleted: isDeleted == 1,
    ).toMap();
  }

  Future<void> apply({List<dynamic> upserts = const [], List<dynamic> deletes = const []}) {
    return ExportService().applyDeltaFromJson(
      jsonEncode({
        'delta_version': 1,
        'changes': {
          'chat_sessions': {'upserts': upserts, 'deletes': deletes},
        },
      }),
    );
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete('chat_sessions', where: 'id LIKE ?', whereArgs: ['xdel_%']);
    await db.delete(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id LIKE ?",
      whereArgs: ['xdel_%'],
    );
  });

  test('远端 deletes 在本端物理删行', () async {
    final id = testId('remote');
    await db.insert('chat_sessions', sessionMap(id));

    await apply(deletes: [id]);

    expect(await repo.getChatSession(id), isNull);
    expect(
      await db.query('chat_sessions', where: 'id = ?', whereArgs: [id]),
      isEmpty,
      reason: '只打 is_deleted 标记的话，占用永远留在库里',
    );
  });

  test('行已不存在时收到 deletes 仍不报错，并补写墓碑继续向第三端转发', () async {
    final id = testId('forward');

    await apply(deletes: [id]);

    final logs = await db.query(
      'sync_log',
      where: "table_name = 'chat_sessions' AND record_id = ? AND operation = 'delete'",
      whereArgs: [id],
    );
    expect(
      logs,
      hasLength(1),
      reason: '旧实现遇行不存在直接 return，删除事件在这台设备上就断了',
    );
  });

  test('对端推来的软删墓碑不会被当普通会话插回本地', () async {
    final id = testId('tombstone');

    await apply(upserts: [sessionMap(id, isDeleted: 1)]);

    expect(
      await db.query('chat_sessions', where: 'id = ?', whereArgs: [id]),
      isEmpty,
      reason: '写回即复活，且还会随本端快照再传染给其它设备',
    );
  });

  test('正常会话仍可同步进来', () async {
    final id = testId('alive');

    await apply(upserts: [sessionMap(id)]);

    final session = await repo.getChatSession(id);
    expect(session, isNotNull);
    expect(session!.title, '远端来的对话');
    expect(session.isDeleted, isFalse);

    await repo.hardDeleteChatSession(id);
  });
}
