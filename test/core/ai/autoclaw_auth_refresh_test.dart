import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/ai/autoclaw_auth_service.dart';
import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// AutoClaw 刷新链路：token 轮换、400002 回落到 agent-refresh、失效标记
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  final service = AutoClawAuthService.instance;
  final repo = AiAccountRepository.instance;
  late _RefreshAdapter adapter;

  String jwt(Map<String, dynamic> claims) {
    String enc(dynamic value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${enc({'alg': 'none'})}.${enc(claims)}.sig';
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete(AiAccountRepository.tableName);
    service.resetForTest();
    adapter = _RefreshAdapter();
    service.httpClientAdapterForTest = adapter;
  });

  tearDown(() => service.resetForTest());

  Future<void> seedExpired() async {
    await repo.upsert(
      AiAccount(
        id: 'a1',
        providerId: 'p1',
        kind: AiAccount.kindAutoClaw,
        accessToken: 'old-access',
        refreshToken: jwt({'device_id': 'dev-1', 'source_id': 'agent-login', 'exp': 2000000000}),
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        uid: 'u1',
        phone: '138****8000',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  test('刷新成功：保存新 token、脱敏手机号与 uid', () async {
    await seedExpired();
    final nextAccess = jwt({'sub': 'u1', 'name': '小浣熊用户', 'device_id': 'dev-1', 'exp': 2000000000});
    adapter.scripts['/userapi/v1/refresh'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'access_token': nextAccess,
            'refresh_token': jwt({'device_id': 'dev-1', 'exp': 2000000000}),
          },
        },
      ),
    ];
    adapter.scripts['/userapi/v1/user-profile'] = [
      (
        200,
        {
          'code': 0,
          'data': {'user_id': 'u1', 'user_name': '小浣熊用户', 'user_phone': '13800138000'},
        },
      ),
    ];

    final next = await service.refreshAccount('a1', force: true);

    expect(next.accessToken, nextAccess);
    expect(next.status, AiAccount.statusActive);
    expect(next.phone, '138****8000');
    expect(next.displayName, '小浣熊用户');
    final stored = await repo.getById('a1');
    expect(stored?.accessToken, nextAccess);
    expect(stored?.refreshToken, isNot('old-access'));
  });

  test('refresh 返回 400002 时自动改用 agent-refresh', () async {
    await seedExpired();
    adapter.scripts['/userapi/v1/refresh'] = [
      (200, {'code': 400002, 'msg': 'unsupported'}),
    ];
    adapter.scripts['/userapi/v1/agent-refresh'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'access_token': jwt({'exp': 2000000000}),
            'refresh_token': jwt({'exp': 2000000000}),
          },
        },
      ),
    ];

    final next = await service.refreshAccount('a1', force: true);

    expect(next.status, AiAccount.statusActive);
    expect(adapter.refreshCalls, 1);
    expect(adapter.agentRefreshCalls, 1);
  });

  test('invalid_grant：标记账号过期并抛出登录失效', () async {
    await seedExpired();
    adapter.scripts['/userapi/v1/refresh'] = [
      (200, {'code': 400001, 'msg': 'invalid_grant'}),
    ];

    await expectLater(
      service.refreshAccount('a1', force: true),
      throwsA(isA<AccountAuthRequiredException>().having((error) => error.message, 'message', 'AutoClaw 登录已失效，请重新登录')),
    );
    final stored = await repo.getById('a1');
    expect(stored?.status, AiAccount.statusExpired);
  });
}

class _RefreshAdapter implements HttpClientAdapter {
  final Map<String, List<(int, Map<String, dynamic>)>> scripts = {};
  int refreshCalls = 0;
  int agentRefreshCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/userapi/v1/refresh')) refreshCalls++;
    if (path.endsWith('/userapi/v1/agent-refresh')) agentRefreshCalls++;
    final script = scripts.entries.where((entry) => path.endsWith(entry.key)).map((entry) => entry.value).firstOrNull;
    if (script == null) {
      return _json(200, {'code': 0, 'data': <String, dynamic>{}});
    }
    final (status, payload) = script.first;
    return _json(status, payload);
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody _json(int status, Map<String, dynamic> body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
