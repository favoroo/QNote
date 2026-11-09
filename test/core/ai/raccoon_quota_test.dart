import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 小浣熊账号额度查询：余额主口径 + setting_info 回落 + 401 刷新重试
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RaccoonAuthService auth;
  late _QuotaAdapter adapter;
  late List<AiAccount> saved;

  AiAccount account({String access = 'access-1'}) {
    final now = DateTime(2026, 1, 1);
    return AiAccount(
      id: 'a1',
      providerId: 'pRaccoon',
      accessToken: access,
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      uid: 'u1',
      phone: '138****8000',
      createdAt: now,
      updatedAt: now,
    );
  }

  setUp(() {
    auth = RaccoonAuthService.instance;
    auth.resetForTest();
    saved = [];
    RaccoonAuthService.accountsLoaderForTest = (_) async => [account()];
    RaccoonAuthService.accountSaverForTest = (item) async {
      saved.removeWhere((old) => old.id == item.id);
      saved.add(item);
    };
    adapter = _QuotaAdapter();
    auth.httpClientAdapterForTest = adapter;
  });

  tearDown(() => auth.resetForTest());

  test('余额接口成功：返回积分与套餐，不触碰 setting_info', () async {
    adapter.balance = [
      (
        200,
        {
          'code': 0,
          'data': {'available_points': 12345},
        }
      ),
    ];
    adapter.entitlement = [
      (
        200,
        {
          'code': 0,
          'data': {
            'office': {
              'pro_enable': true,
              'active_plan': {'type': 'Pro'},
              'pro_expired_time': '2027-01-01T00:00:00Z',
            },
          },
        }
      ),
    ];

    final quota = await auth.fetchQuota(account());

    expect(quota.balance, 12345);
    expect(quota.plan, 'Pro');
    expect(
      quota.planExpiresAt?.toUtc(),
      DateTime.utc(2027, 1, 1),
    );
    expect(adapter.settingCalls, 0);
  });

  test('余额 403 时回落到 setting_info；套餐读不到不影响积分', () async {
    adapter.balance = [
      (403, {'code': 403001, 'details': 'balance is forbidden'}),
    ];
    adapter.setting = [
      (
        200,
        {
          'code': 0,
          'data': {'available_points': 6789},
        }
      ),
    ];
    adapter.entitlement = [
      (500, {'code': 500001, 'details': 'entitlement unavailable'}),
    ];

    final quota = await auth.fetchQuota(account());

    expect(quota.balance, 6789);
    expect(quota.hasPlan, isFalse);
    expect(quota.planExpiresAt, isNull);
    expect(adapter.settingCalls, 1);
  });

  test('token 被拒：刷新一次后用新 token 重查', () async {
    adapter.balance = [
      (401, {'code': 200001, 'details': 'authorization invalid'}),
      (
        200,
        {
          'code': 0,
          'data': {'available_points': 100},
        }
      ),
    ];
    adapter.entitlement = [
      (
        200,
        {
          'code': 0,
          'data': {
            'office': {'pro_enable': false},
          },
        }
      ),
    ];
    RaccoonAuthService.accountRefresherForTest = (current) async =>
        current.copyWith(accessToken: 'access-2');

    final quota = await auth.fetchQuota(account());

    expect(quota.balance, 100);
    expect(quota.plan, 'Free');
    expect(adapter.balanceAuth, ['Bearer access-1', 'Bearer access-2']);
    expect(saved, isEmpty);
  });

  test('刷新后仍被拒：标记账号过期并提示重新登录', () async {
    adapter.balance = [
      (401, {'code': 200001, 'details': 'authorization invalid'}),
    ];
    RaccoonAuthService.accountRefresherForTest = (current) async =>
        current.copyWith(accessToken: 'access-2');

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(
        isA<RaccoonAuthRequiredException>().having(
          (error) => error.message,
          'message',
          '小浣熊登录已失效，请重新登录',
        ),
      ),
    );
    expect(adapter.balanceCalls, 2);
    expect(saved.single.status, AiAccount.statusExpired);
    expect(saved.single.accessToken, 'access-2');
  });

  test('没有可用 token 时不发请求，直接要求重新登录', () async {
    await expectLater(
      auth.fetchQuota(account(access: '')),
      throwsA(isA<RaccoonAuthRequiredException>()),
    );
    expect(adapter.balanceCalls, 0);
  });

  test('两处都没有积分时优先报余额接口的厂商文案', () async {
    adapter.balance = [
      (200, {'code': 100001, 'details': 'balance unavailable'}),
    ];
    adapter.setting = [
      (200, {'code': 0, 'data': <String, dynamic>{}}),
    ];

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'balance unavailable',
        ),
      ),
    );
  });
}

class _QuotaAdapter implements HttpClientAdapter {
  List<(int, Map<String, dynamic>)> balance = [];
  List<(int, Map<String, dynamic>)> setting = [];
  List<(int, Map<String, dynamic>)> entitlement = [];
  int balanceCalls = 0;
  int settingCalls = 0;
  int entitlementCalls = 0;
  final List<String> balanceAuth = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/points/v1/balance')) {
      balanceCalls++;
      balanceAuth.add(_header(options.headers, 'authorization'));
      final (status, body) = _pick(balance, balanceCalls);
      return _json(status, body);
    }
    if (path.endsWith('/office/v3/setting_info')) {
      settingCalls++;
      final (status, body) = _pick(setting, settingCalls);
      return _json(status, body);
    }
    if (path.endsWith('/auth/v1/entitlement_info')) {
      entitlementCalls++;
      final (status, body) = _pick(entitlement, entitlementCalls);
      return _json(status, body);
    }
    return _json(404, {'code': 404, 'details': 'not found'});
  }

  @override
  void close({bool force = false}) {}

  static (int, Map<String, dynamic>) _pick(
    List<(int, Map<String, dynamic>)> script,
    int call,
  ) {
    if (script.isEmpty) {
      return (200, {'code': 0, 'data': <String, dynamic>{}});
    }
    return script[math.min(call - 1, script.length - 1)];
  }

  static String _header(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) {
        return entry.value?.toString() ?? '';
      }
    }
    return '';
  }

  static ResponseBody _json(int status, Map<String, dynamic> body) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}