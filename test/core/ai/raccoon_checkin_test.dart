import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 小浣熊手动签到：setting_info 触发 + 账单快照/差异确认 + 401 刷新重试
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RaccoonAuthService auth;
  late _CheckInAdapter adapter;
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
    adapter = _CheckInAdapter();
    auth.httpClientAdapterForTest = adapter;
  });

  tearDown(() => auth.resetForTest());

  test('首次签到：账单新增 daily_grant 时报告到账积分与事件名', () async {
    adapter.bills = [
      (
        200,
        {
          'code': 0,
          'data': {'items': <Map<String, dynamic>>[]},
        },
      ),
      (
        200,
        {
          'code': 0,
          'data': {
            'items': [_bill(points: 300, event: '每日签到', biz: 'daily_grant')],
          },
        },
      ),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isTrue);
    expect(result.credit, 300);
    expect(result.message, contains('每日签到'));
    expect(result.message, contains('+300'));
    // 签到触发器要带桌面端请求头，否则厂商不发当日积分
    expect(adapter.settingHeaders.single['X-Client-Platform'], isNotNull);
    expect(adapter.settingHeaders.single['X-Raccoon-Language'], 'zh');
    expect(saved, isEmpty);
  });

  test('今天已签过：账单没有新增时不重复报积分', () async {
    final bill = _bill(points: 300, event: '每日签到', biz: 'daily_grant');
    adapter.bills = [
      (
        200,
        {
          'code': 0,
          'data': {
            'items': [bill],
          },
        },
      ),
      (
        200,
        {
          'code': 0,
          'data': {
            'items': [bill],
          },
        },
      ),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isFalse);
    expect(result.credit, 0);
    expect(result.message, '今日已签到');
  });

  test('昨天或消费类账单不算签到发放', () async {
    final yesterday = DateTime.now().toUtc().add(const Duration(hours: 8)).subtract(const Duration(days: 1));
    String two(int value) => value.toString().padLeft(2, '0');
    final oldDate = '${yesterday.year}-${two(yesterday.month)}-${two(yesterday.day)}';
    adapter.bills = [
      (
        200,
        {
          'code': 0,
          'data': {'items': <Map<String, dynamic>>[]},
        },
      ),
      (
        200,
        {
          'code': 0,
          'data': {
            'items': [
              _bill(points: 300, event: '每日签到', biz: 'daily_grant', date: oldDate),
              _bill(points: -120, event: '对话消耗', biz: 'chat_consume'),
            ],
          },
        },
      ),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isFalse);
    expect(result.credit, 0);
  });

  test('签到接口 401 时刷新一次，用新 token 重签', () async {
    adapter.bills = [
      (
        200,
        {
          'code': 0,
          'data': {'items': <Map<String, dynamic>>[]},
        },
      ),
      (
        200,
        {
          'code': 0,
          'data': {'items': <Map<String, dynamic>>[]},
        },
      ),
      (
        200,
        {
          'code': 0,
          'data': {
            'items': [_bill(points: 300, event: '每日签到', biz: 'daily_grant')],
          },
        },
      ),
    ];
    adapter.setting = [
      (401, {'code': 200001, 'details': 'authorization invalid'}),
      (200, {'code': 0, 'data': <String, dynamic>{}}),
    ];
    RaccoonAuthService.accountRefresherForTest = (current) async => current.copyWith(accessToken: 'access-2');

    final result = await auth.checkIn(account());

    expect(result.claimed, isTrue);
    expect(result.credit, 300);
    expect(adapter.settingAuth, ['Bearer access-1', 'Bearer access-2']);
    expect(saved, isEmpty);
  });

  test('刷新后仍被拒：标记账号过期并提示重新登录', () async {
    adapter.bills = [
      (
        200,
        {
          'code': 0,
          'data': {'items': <Map<String, dynamic>>[]},
        },
      ),
    ];
    adapter.setting = [
      (401, {'code': 200001, 'details': 'authorization invalid'}),
    ];
    RaccoonAuthService.accountRefresherForTest = (current) async => current.copyWith(accessToken: 'access-2');

    await expectLater(
      auth.checkIn(account()),
      throwsA(isA<RaccoonAuthRequiredException>().having((error) => error.message, 'message', '小浣熊登录已失效，请重新登录')),
    );
    expect(adapter.settingCalls, 2);
    expect(saved.single.status, AiAccount.statusExpired);
  });

  test('签到前账单读不到时退化为已签到，不虚报积分', () async {
    adapter.bills = [
      (500, {'code': 500001, 'details': 'bills unavailable'}),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isFalse);
    expect(result.credit, 0);
    expect(result.message, '今日已签到');
    // 快照失败后不再读第二次账单：没有对比基线，读了也无法判断
    expect(adapter.billsCalls, 1);
    expect(adapter.settingCalls, 1);
  });

  test('没有可用 token 时不发请求，直接要求重新登录', () async {
    await expectLater(auth.checkIn(account(access: '')), throwsA(isA<RaccoonAuthRequiredException>()));
    expect(adapter.billsCalls, 0);
    expect(adapter.settingCalls, 0);
  });
}

String _beijingToday() {
  final now = DateTime.now().toUtc().add(const Duration(hours: 8));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}';
}

Map<String, dynamic> _bill({required int points, required String event, required String biz, String? date}) {
  return {
    'bill_id': 'bill-$points-$event-$biz-${date ?? ''}',
    'points': points,
    'event_name': event,
    'biz_type': biz,
    'created_at': '${date ?? _beijingToday()}T09:00:00+08:00',
  };
}

class _CheckInAdapter implements HttpClientAdapter {
  List<(int, Map<String, dynamic>)> bills = [];
  List<(int, Map<String, dynamic>)> setting = [];
  int billsCalls = 0;
  int settingCalls = 0;
  final List<Map<String, dynamic>> settingHeaders = [];
  final List<String> settingAuth = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/points/v1/bills')) {
      billsCalls++;
      final (status, body) = _pick(bills, billsCalls);
      return _json(status, body);
    }
    if (path.endsWith('/office/v3/setting_info')) {
      settingCalls++;
      settingAuth.add(_header(options.headers, 'authorization'));
      settingHeaders.add({
        for (final entry in options.headers.entries)
          if (entry.value != null) entry.key: entry.value.toString(),
      });
      final (status, body) = _pick(setting, settingCalls);
      return _json(status, body);
    }
    return _json(404, {'code': 404, 'details': 'not found'});
  }

  @override
  void close({bool force = false}) {}

  static (int, Map<String, dynamic>) _pick(List<(int, Map<String, dynamic>)> script, int call) {
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

  static ResponseBody _json(int status, Map<String, dynamic> body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
