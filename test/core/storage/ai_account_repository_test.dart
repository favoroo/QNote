import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 订阅账号仓储测试。
///
/// 顺带走一次 DatabaseHelper 建库：锁住 v30 的 `ai_accounts` 表与
/// `ai_providers.auth_mode` 列真实存在，避免只在 Dart 模型里「看起来能存」。
void main() {
  late Database db;
  final repo = AiAccountRepository.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete(AiAccountRepository.tableName);
  });

  AiAccount account({
    String id = 'a1',
    String providerId = 'p1',
    String access = 'access-1',
    String refresh = 'refresh-1',
    String status = AiAccount.statusActive,
    bool enabled = true,
    int sortOrder = 0,
  }) {
    final now = DateTime(2026, 1, 1);
    return AiAccount(
      id: id,
      providerId: providerId,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime(2026, 1, 1, 12),
      uid: 'u1',
      displayName: '张三',
      phone: '138****8000',
      status: status,
      enabled: enabled,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('upsert 后可按 id 取回完整登录态', () async {
    await repo.upsert(account());

    final saved = await repo.getById('a1');
    expect(saved, isNotNull);
    expect(saved!.providerId, 'p1');
    expect(saved.accessToken, 'access-1');
    expect(saved.refreshToken, 'refresh-1');
    expect(saved.uid, 'u1');
    expect(saved.displayName, '张三');
    expect(saved.phone, '138****8000');
    expect(saved.expiresAt, DateTime(2026, 1, 1, 12));
    expect(saved.isExpired, isFalse);
  });

  test('同一 id 再次 upsert 覆盖而不新增行', () async {
    await repo.upsert(account());
    await repo.upsert(account(access: 'access-2', status: AiAccount.statusExpired));

    final all = await repo.getAll();
    expect(all.length, 1);
    expect(all.single.accessToken, 'access-2');
    expect(all.single.isExpired, isTrue);
  });

  test('同一厂商下可存多个账号，按 sort_order 排序', () async {
    await repo.upsert(account(id: 'a2', access: 'access-2', sortOrder: 1));
    await repo.upsert(account(id: 'a1', access: 'access-1', sortOrder: 0));
    await repo.upsert(account(id: 'b1', providerId: 'p2', sortOrder: 0));

    final forP1 = await repo.getByProvider('p1');
    expect(forP1.map((a) => a.id).toList(), ['a1', 'a2']);
    expect((await repo.getAll()).length, 3);
  });

  test('delete 清掉指定账号，deleteByProvider 清掉整组', () async {
    await repo.upsert(account(id: 'a1'));
    await repo.upsert(account(id: 'a2'));
    await repo.delete('a1');
    expect(await repo.getById('a1'), isNull);
    expect(await repo.getById('a2'), isNotNull);

    await repo.deleteByProvider('p1');
    expect(await repo.getByProvider('p1'), isEmpty);
  });

  test('ai_providers 表有 auth_mode 列，ai_accounts 不写 sync_log', () async {
    final columns = await db.rawQuery('PRAGMA table_info(ai_providers)');
    final names = columns.map((c) => c['name'] as String).toSet();
    expect(names.contains('auth_mode'), isTrue);

    await repo.upsert(account());
    final logs = await db.query('sync_log', where: 'table_name = ?', whereArgs: [AiAccountRepository.tableName]);
    expect(logs, isEmpty, reason: '刷新 token 不能随同步广播到其他设备');
  });
}
