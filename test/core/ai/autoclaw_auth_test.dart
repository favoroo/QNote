import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/autoclaw_auth_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// AutoClaw 国内版：短信登录、刷新、额度、签到与网关请求适配
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AutoClawAuthService auth;
  late _AutoClawAdapter adapter;
  late List<AiAccount> saved;

  AiAccount account({
    String id = 'a1',
    String access = 'access-1',
    String refresh = 'refresh-1',
  }) {
    final now = DateTime(2026, 1, 1);
    return AiAccount(
      id: id,
      providerId: 'pAutoClaw',
      kind: AiAccount.kindAutoClaw,
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      uid: 'u1',
      phone: '138****8000',
      createdAt: now,
      updatedAt: now,
    );
  }

  setUp(() {
    auth = AutoClawAuthService.instance;
    auth.resetForTest();
    saved = [];
    AutoClawAuthService.accountsLoaderForTest = (_) async => [account()];
    AutoClawAuthService.accountSaverForTest = (item) async {
      saved.removeWhere((old) => old.id == item.id);
      saved.add(item);
    };
    adapter = _AutoClawAdapter();
    auth.httpClientAdapterForTest = adapter;
  });

  tearDown(() => auth.resetForTest());

  test('短信登录：发码 → 验码 → 落库为 AutoClaw 账号', () async {
    final access = _jwt(exp: _futureSeconds());
    adapter.scripts['/userapi/v1/agent-send-code'] = [
      (200, {'code': 0, 'msg': 'ok'}),
    ];
    adapter.scripts['/userapi/v1/agent-login/'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'access_token': access,
            'refresh_token': _jwt(
              exp: _futureSeconds() + 86400,
              device: 'dev-1',
            ),
            'user_id': 'u1',
          },
        },
      ),
    ];
    adapter.scripts['/userapi/v1/user-profile'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'user_id': 'u1',
            'user_name': '小浣熊用户',
            'user_phone': '13800138000',
          },
        },
      ),
    ];

    final challenge = await auth.sendLoginCode('pAutoClaw', '13800138000');
    final result = await auth.verifyLoginCode(
      'pAutoClaw',
      challenge,
      '123456',
    );

    expect(result.kind, AiAccount.kindAutoClaw);
    expect(result.uid, 'u1');
    expect(result.displayName, '小浣熊用户');
    expect(result.phone, '138****8000');
    expect(result.refreshToken, isNotEmpty);
    expect(saved.single.id, result.id);

    // 登录请求必须带短信验证码（数字）与同一个 device_id
    final loginBody = adapter.calls
        .firstWhere((call) => call.path.contains('/agent-login'))
        .body;
    expect(loginBody['code'], 123456);
    expect(loginBody['device_id'], challenge.ticket);
    expect(loginBody['phone'], '13800138000');
    // WAF 签名头
    final headers = adapter.calls
        .firstWhere((call) => call.path.contains('/agent-send-code'))
        .headers;
    expect(headers['X-Auth-Sign'], isNotEmpty);
    expect(headers['X-Product'], 'autoclaw');
    expect(headers['X-Channel'], 'AutoClaw4');
  });

  test('手机号格式不对时直接报错，不发请求', () async {
    await expectLater(
      auth.sendLoginCode('pAutoClaw', '12345'),
      throwsA(isA<FormatException>()),
    );
    expect(adapter.calls, isEmpty);
  });

  test('额度：总余额 + 钱包拆分 + 今日签到状态', () async {
    adapter.scripts['/agent-assetmgr/api/v2/wallets'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'total_balance': 1234,
            'wallets': [
              {'display_name': '赠送积分', 'balance': 500, 'display': true},
              {'display_name': '会员积分', 'balance': 734, 'display': true},
              {'display_name': '合计', 'balance': 1234, 'display': true},
            ],
          },
        },
      ),
    ];
    adapter.scripts['/autoclaw-task-list'] = [
      (
        200,
        {
          'code': 0,
          'data': [
            {
              'task_id': 'daily_signin',
              'status': 'completed',
              'reward_points': 5,
            },
          ],
        },
      ),
    ];

    final quota = await auth.fetchQuota(account());

    expect(quota.balance, 1234);
    expect(quota.detail, contains('每日签到已完成 +5'));
    expect(quota.detail, contains('赠送积分 500'));
    expect(quota.detail, contains('会员积分 734'));
    // 与总额相同的钱包不重复展示
    expect(quota.detail, isNot(contains('合计 1234')));
  });

  test('签到成功：返回奖励与连续天数', () async {
    adapter.scripts['/autoclaw-task-complete'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'success': true,
            'reward_points': 5,
            'continuous_days': 3,
          },
        },
      ),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isTrue);
    expect(result.credit, 5);
    expect(result.message, contains('+5'));
    expect(result.message, contains('连续 3 天'));
    expect(adapter.calls.single.body['task_id'], 'daily_signin');
  });

  test('今天已签过：不重复报积分', () async {
    adapter.scripts['/autoclaw-task-complete'] = [
      (
        200,
        {
          'code': 0,
          'data': {
            'success': false,
            'already_completed': true,
            'reward_points': 5,
          },
        },
      ),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isFalse);
    expect(result.credit, 0);
    expect(result.message, '今日已签到（+5）');
  });

  test('额度接口 401 时刷新一次，用新 token 重查', () async {
    adapter.scripts['/agent-assetmgr/api/v2/wallets'] = [
      (401, {'code': 401, 'message': 'authorization invalid'}),
      (
        200,
        {'code': 0, 'data': {'total_balance': 88, 'wallets': <Map>[]}},
      ),
    ];
    AutoClawAuthService.accountRefresherForTest = (current) async =>
        current.copyWith(accessToken: 'access-2');

    final quota = await auth.fetchQuota(account());

    expect(quota.balance, 88);
    final walletCalls = adapter.calls
        .where((call) => call.path.contains('/wallets'))
        .toList();
    expect(walletCalls.length, 2);
    expect(
      walletCalls.last.headers['Authorization'],
      'Bearer access-2',
    );
  });

  test('刷新后仍被拒：标记账号过期并提示重新登录', () async {
    adapter.scripts['/agent-assetmgr/api/v2/wallets'] = [
      (401, {'code': 401, 'message': 'authorization invalid'}),
      (401, {'code': 401, 'message': 'authorization invalid'}),
    ];
    AutoClawAuthService.accountRefresherForTest = (current) async =>
        current.copyWith(accessToken: 'access-2');

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(
        isA<AccountAuthRequiredException>().having(
          (error) => error.message,
          'message',
          'AutoClaw 登录已失效，请重新登录',
        ),
      ),
    );
    expect(saved.single.status, AiAccount.statusExpired);
  });

  test('403 额度用尽不算登录失效', () async {
    adapter.scripts['/agent-assetmgr/api/v2/wallets'] = [
      (403, {'code': 810000, 'message': '额度已用完'}),
    ];

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('额度已用完'),
        ),
      ),
    );
    expect(saved, isEmpty);
  });

  test('网关请求头：X-Authorization + 国内客户端指纹', () {
    final headers = AutoClawAuthService.requestHeadersForTest(
      'access-1',
      model: 'zaicoding_glm-5.3',
    );

    expect(headers['X-Authorization'], 'Bearer access-1');
    expect(headers['Authorization'], isNull);
    expect(headers['X-Channel'], 'AutoClaw26');
    expect(headers['X-Version'], '2.1.0');
    expect(headers['X-Request-Model'], 'zaicoding_glm-5.3');
    expect(headers['X-Auth-Sign'], isNotEmpty);
  });

  test('请求体：去掉 max_tokens 并补官方 system 前缀', () {
    final body = <String, dynamic>{
      'model': 'zai_auto',
      'max_tokens': 2048,
      'messages': [
        {'role': 'system', 'content': '你是小Q'},
        {'role': 'user', 'content': '你好'},
      ],
      'tools': <Map<String, dynamic>>[],
    };

    AutoClawAuthService.adaptChatBodyForTest(body);

    expect(body.containsKey('max_tokens'), isFalse);
    expect(body.containsKey('tools'), isFalse);
    expect(body.containsKey('tool_choice'), isFalse);
    final messages = body['messages'] as List;
    expect(
      (messages.first as Map)['content'],
      startsWith(AutoClawAuthService.officialSystemPrompt),
    );
    expect((messages.first as Map)['content'], contains('你是小Q'));
  });

  test('没有 token 时不发请求，直接要求重新登录', () async {
    AutoClawAuthService.accountsLoaderForTest = (_) async => [
      account(access: ''),
    ];

    await expectLater(
      auth.fetchQuota(account(access: '')),
      throwsA(isA<AccountAuthRequiredException>()),
    );
    expect(adapter.calls, isEmpty);
  });
}

int _futureSeconds() {
  return DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
}

String _jwt({int? exp, String sub = 'u1', String device = 'dev-1'}) {
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none'})}.${encode({
        'exp': exp ?? _futureSeconds(),
        'sub': sub,
        'device_id': device,
      })}.sig';
}

class _Call {
  final String path;
  final Map<String, dynamic> body;
  final Map<String, dynamic> headers;

  const _Call({
    required this.path,
    required this.body,
    required this.headers,
  });
}

class _AutoClawAdapter implements HttpClientAdapter {
  final Map<String, List<(int, Map<String, dynamic>)>> scripts = {};
  final List<_Call> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final data = options.data;
    final body = data is Map
        ? Map<String, dynamic>.from(data)
        : <String, dynamic>{};
    calls.add(
      _Call(
        path: path,
        body: body,
        headers: {
          for (final entry in options.headers.entries)
            if (entry.value != null) entry.key: entry.value.toString(),
        },
      ),
    );
    final script = scripts.entries
        .where((entry) => path.endsWith(entry.key) || path.startsWith(entry.key))
        .map((entry) => entry.value)
        .firstOrNull;
    if (script == null) {
      return _json(200, {'code': 0, 'data': <String, dynamic>{}});
    }
    final index = calls.where((call) => call.path == path).length - 1;
    final (status, payload) = script[math.min(index, script.length - 1)];
    return _json(status, payload);
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody _json(int status, Map<String, dynamic> body) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}