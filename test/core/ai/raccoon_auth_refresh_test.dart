import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 小浣熊刷新链路：换新 access/refresh、保存脱敏手机号、401 标记失效
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  final service = RaccoonAuthService.instance;
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

  Future<void> seedExpired() async {
    await repo.upsert(
      AiAccount(
        id: 'a1',
        providerId: 'p1',
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        uid: 'u1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  test('刷新成功后保存新 token、refresh 与脱敏手机号', () async {
    await seedExpired();
    final nextAccess = jwt({'name': '李四', 'exp': 2000000000});
    adapter.refreshBody = {
      'data': {'access_token': nextAccess, 'refresh_token': 'new-refresh'},
    };
    adapter.phoneBody = {
      'data': {'phone': '13800138000'},
    };

    final account = await service.refreshAccount('a1', force: true);

    expect(account.accessToken, nextAccess);
    expect(account.refreshToken, 'new-refresh');
    expect(account.displayName, '李四');
    expect(account.phone, '138****8000');
    expect(account.isExpired, isFalse);

    final stored = await repo.getById('a1');
    expect(stored?.accessToken, nextAccess);
    expect(stored?.refreshToken, 'new-refresh');
    expect(stored?.phone, '138****8000');
  });

  test('刷新被 401 拒绝时把账号标记为 expired', () async {
    await seedExpired();
    adapter.refreshStatus = 401;
    adapter.refreshBody = {'message': 'invalid refresh token'};

    await expectLater(service.refreshAccount('a1', force: true), throwsA(isA<RaccoonAuthRequiredException>()));

    final stored = await repo.getById('a1');
    expect(stored?.isExpired, isTrue);
    expect(await service.accessTokenFor('p1'), isNull);
  });
}

class _RefreshAdapter implements HttpClientAdapter {
  int refreshStatus = 200;
  Map<String, dynamic> refreshBody = {};
  Map<String, dynamic> phoneBody = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/auth/v1/refresh')) {
      final data = options.data;
      expect(data, isA<Map>());
      expect((data as Map)['refresh_token'], 'old-refresh');
      return _json(refreshBody, status: refreshStatus);
    }
    if (path.endsWith('/auth/v1/user_info')) {
      return _json(phoneBody);
    }
    return _json({'message': 'unexpected path $path'}, status: 404);
  }

  ResponseBody _json(Map<String, dynamic> body, {int status = 200}) {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
