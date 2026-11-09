import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';

/// v30 → v31 多账号 schema 迁移：老库里的登录态必须原样搬到新表，不能要求重登
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('老库（provider_id 主键）升级后按 id 取回账号，且新增列齐全', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 31),
    );
    addTearDown(db.close);

    // 重建 v30 的两张表
    await db.execute('''
      CREATE TABLE ai_accounts (
        provider_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL DEFAULT 'raccoon',
        access_token TEXT NOT NULL,
        refresh_token TEXT NOT NULL DEFAULT '',
        expires_at TEXT,
        uid TEXT,
        display_name TEXT,
        phone TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE ai_providers (
        id TEXT PRIMARY KEY,
        vendor_id TEXT,
        name TEXT NOT NULL,
        provider_type TEXT NOT NULL,
        base_url TEXT NOT NULL,
        auth_mode TEXT NOT NULL DEFAULT 'api_key',
        api_keys TEXT NOT NULL,
        models TEXT NOT NULL,
        model_catalog TEXT,
        catalog_updated_at TEXT,
        is_default INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.insert('ai_accounts', {
      'provider_id': 'p1',
      'access_token': 'old-access',
      'refresh_token': 'old-refresh',
      'uid': 'u1',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00.000',
      'updated_at': '2026-01-01T00:00:00.000',
    });
    await db.insert('ai_providers', {
      'id': 'p1',
      'vendor_id': 'raccoon',
      'name': '小浣熊',
      'provider_type': 'openai',
      'base_url': 'https://xiaohuanxiong.com/api/web/llm/v2',
      'api_keys': '[]',
      'models': '[]',
      'created_at': '2026-01-01T00:00:00.000',
      'updated_at': '2026-01-01T00:00:00.000',
    });

    await DatabaseHelper.ensureMultiAccountSchema(db);

    final accounts = await db.query('ai_accounts');
    expect(accounts.length, 1);
    expect(accounts.single['id'], 'p1', reason: '老库用 provider_id 当新主键');
    expect(accounts.single['provider_id'], 'p1');
    expect(accounts.single['access_token'], 'old-access');
    expect(accounts.single['refresh_token'], 'old-refresh');
    expect(accounts.single['alias'], '');
    expect(accounts.single['enabled'], 1);
    expect(accounts.single['sort_order'], 0);

    final providerColumns = await db.rawQuery('PRAGMA table_info(ai_providers)');
    final names = providerColumns.map((c) => c['name'] as String).toSet();
    expect(names.contains('account_routing'), isTrue);
    expect(names.contains('account_affinity'), isTrue);
    // v32 的厂商级停用开关：老库补列后按「启用」处理，不能把老用户的服务停掉
    expect(names.contains('enabled'), isTrue);

    final provider = (await db.query('ai_providers')).single;
    expect(provider['account_routing'], 'rotate');
    expect(provider['account_affinity'], 'session');
    expect(provider['enabled'], 1);
  });

  test('已经是 v31 结构时重复执行不破坏数据（onOpen 兜底幂等）', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 31),
    );
    addTearDown(db.close);

    await db.execute('''
      CREATE TABLE ai_accounts (
        id TEXT PRIMARY KEY,
        provider_id TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'raccoon',
        alias TEXT NOT NULL DEFAULT '',
        access_token TEXT NOT NULL,
        refresh_token TEXT NOT NULL DEFAULT '',
        expires_at TEXT,
        uid TEXT,
        display_name TEXT,
        phone TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        enabled INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.insert('ai_accounts', {
      'id': 'a1',
      'provider_id': 'p1',
      'access_token': 't1',
      'created_at': '2026-01-01T00:00:00.000',
      'updated_at': '2026-01-01T00:00:00.000',
    });

    await DatabaseHelper.ensureMultiAccountSchema(db);
    await DatabaseHelper.ensureMultiAccountSchema(db);

    final accounts = await db.query('ai_accounts');
    expect(accounts.length, 1);
    expect(accounts.single['id'], 'a1');
    expect(accounts.single['access_token'], 't1');
  });
}