import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/loomy_auth_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// Loomy（讯飞）：签名登录、额度、签到与网关协议适配
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoomyAuthService auth;
  late _LoomyAdapter adapter;
  late List<AiAccount> saved;

  AiAccount account({
    String id = 'a1',
    String access = 'session-1',
    String status = AiAccount.statusActive,
    Duration ttl = const Duration(days: 7),
  }) {
    final now = DateTime(2026, 1, 1);
    return AiAccount(
      id: id,
      providerId: 'pLoomy',
      kind: AiAccount.kindLoomy,
      accessToken: access,
      expiresAt: DateTime.now().add(ttl),
      uid: 'u1',
      phone: '138****8000',
      status: status,
      createdAt: now,
      updatedAt: now,
    );
  }

  setUp(() {
    auth = LoomyAuthService.instance;
    auth.resetForTest();
    saved = [];
    LoomyAuthService.accountsLoaderForTest = (_) async => [account()];
    LoomyAuthService.accountSaverForTest = (item) async {
      saved.removeWhere((old) => old.id == item.id);
      saved.add(item);
    };
    adapter = _LoomyAdapter();
    auth.httpClientAdapterForTest = adapter;
  });

  tearDown(() => auth.resetForTest());

  test('短信登录：发码（带 HMAC 签名）→ 验码 → 落库为 Loomy 账号', () async {
    adapter.scripts['/login/phone/sendMsgCode'] = [
      (
        200,
        {
          'code': '000000',
          'desc': 'ok',
          'data': {'msgid': 'msg-1'},
        },
      ),
    ];
    adapter.scripts['/login/phone/checkCode'] = [
      (
        200,
        {
          'code': '000000',
          'data': {'session': 'session-xyz', 'userid': 'u9'},
        },
      ),
    ];

    final challenge = await auth.sendLoginCode('pLoomy', '13800138000');
    final result = await auth.verifyLoginCode(
      'pLoomy',
      challenge,
      '123456',
    );

    expect(result.kind, AiAccount.kindLoomy);
    expect(result.accessToken, 'session-xyz');
    // 没有续期接口，refresh 必须为空
    expect(result.refreshToken, isEmpty);
    expect(result.uid, 'u9');
    expect(result.phone, '138****8000');
    expect(result.status, AiAccount.statusActive);
    // 14 天有效期（允许几秒误差）
    final remaining = result.expiresAt!.difference(DateTime.now());
    expect(remaining.inDays, 13);
    expect(saved.single.id, result.id);

    final checkBody = adapter.calls
        .firstWhere((call) => call.path.contains('checkCode'))
        .body;
    expect(checkBody['param']['mcode'], '123456');
    expect(checkBody['param']['msgid'], 'msg-1');
    expect(checkBody['param']['phone'], '13800138000');
    expect(checkBody['param']['ccode'], '86');
    expect(checkBody['base']['appid'], 'GM3LOOMY');

    // 账号域必须带 HMAC-SHA1 签名头，且 Content-MD5 与实际发出的字节一致
    final sendCall = adapter.calls.firstWhere(
      (call) => call.path.contains('sendMsgCode'),
    );
    expect(sendCall.headers['Authorization'], startsWith('account '));
    expect(sendCall.headers['Nonce'], isNotEmpty);
    expect(sendCall.headers['Date'], endsWith('GMT'));
    expect(sendCall.bodyString, isNotEmpty);
    expect(
      sendCall.headers['Content-MD5'],
      base64Encode(md5.convert(utf8.encode(sendCall.bodyString)).bytes),
    );
  });

  test('手机号格式不对时直接报错，不发请求', () async {
    await expectLater(
      auth.sendLoginCode('pLoomy', '12345'),
      throwsA(isA<FormatException>()),
    );
    expect(adapter.calls, isEmpty);
  });

  test('验证码不是 6 位时直接报错，不发请求', () async {
    const challenge = AccountSmsChallenge(phone: '13800138000', ticket: 'm1');
    await expectLater(
      auth.verifyLoginCode('pLoomy', challenge, '12345'),
      throwsA(isA<FormatException>()),
    );
    expect(adapter.calls, isEmpty);
  });

  test('额度：永久积分 + 每日赠送积分两个钱包', () async {
    adapter.scripts['/api/v2/points/records'] = [
      (
        200,
        {
          'code': '000000',
          'data': {
            'data': {
              'balance': 300,
              'dailyBalance': 40,
              'dailyLimitPoints': 100,
              'dailyRemainingPoints': 40,
            },
          },
        },
      ),
    ];

    final quota = await auth.fetchQuota(account());

    // 主数值 = 永久 + 每日剩余，否则「积分」会漏掉每天赠送的那部分
    expect(quota.balance, 340);
    expect(quota.detail, '每日赠送 40/100 · 永久 300');
    // 网关要同时带 token 与 Authorization
    final call = adapter.calls.single;
    expect(call.headers['token'], 'session-1');
    expect(call.headers['Authorization'], 'Bearer session-1');
    expect(call.headers['Content-Type'], contains('charset=utf-8'));
  });

  test('额度响应没有余额字段时报「未知」，不冒充 0', () async {
    adapter.scripts['/api/v2/points/records'] = [
      (
        200,
        {
          'code': '000000',
          'data': {'data': {'records': <dynamic>[]}},
        },
      ),
    ];

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(isA<FormatException>()),
    );
  });

  test('签到：每日余额上涨算领到，返回本次到账积分', () async {
    adapter.scripts['/api/v2/points/records'] = [
      (200, {'code': '000000', 'data': {'dailyBalance': 40}}),
      (200, {'code': '000000', 'data': {'dailyBalance': 65}}),
    ];
    adapter.scripts['/api/v1/points/first-login'] = [
      (200, {'code': '000000', 'data': <String, dynamic>{}}),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isTrue);
    expect(result.credit, 25);
    expect(result.message, contains('+25'));
    // 签到接口按天幂等，body 必须是空对象
    final call = adapter.calls.firstWhere(
      (call) => call.path.contains('first-login'),
    );
    expect(call.body, isEmpty);
  });

  test('签到：余额没变算「今日已领取」，不虚报奖励', () async {
    adapter.scripts['/api/v2/points/records'] = [
      (200, {'code': '000000', 'data': {'dailyBalance': 40}}),
      (200, {'code': '000000', 'data': {'dailyBalance': 40}}),
    ];
    adapter.scripts['/api/v1/points/first-login'] = [
      (200, {'code': '000000', 'data': <String, dynamic>{}}),
    ];

    final result = await auth.checkIn(account());

    expect(result.claimed, isFalse);
    expect(result.credit, 0);
    expect(result.message, '今日已领取（当前 40）');
  });

  test('登录态失效（业务码 020002）时抛「请重新登录」', () async {
    adapter.scripts['/api/v2/points/records'] = [
      (200, {'code': '020002', 'desc': 'token invalid'}),
    ];

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(isA<AccountAuthRequiredException>()),
    );
  });

  test('HTTP 401 也算登录失效', () async {
    adapter.scripts['/api/v2/points/records'] = [
      (401, {'code': '000000', 'desc': 'unauthorized'}),
    ];

    await expectLater(
      auth.fetchQuota(account()),
      throwsA(isA<AccountAuthRequiredException>()),
    );
  });

  test('session 临期时直接判失效并标记过期（没有续期接口）', () async {
    final expired = account(ttl: const Duration(minutes: 10));

    final token = await auth.accessTokenForAccount(expired);

    expect(token, isNull);
    expect(saved.single.status, AiAccount.statusExpired);
  });

  test('模型目录：实时目录优先，展示名去掉倍率后缀', () async {
    adapter.scripts['/api/v1/models'] = [
      (
        200,
        {
          'code': '000000',
          'data': [
            {
              'id': 'Kimi-k2.6',
              'name': 'Kimi k2.6 (x6.5)',
              'capabilities': {'vision': true},
            },
            {'id': 'auto', 'name': '自动 · 均衡'},
            {'id': 'Kimi-k2.6', 'name': '重复项'},
          ],
        },
      ),
    ];

    final models = await auth.fetchModelsForProvider('pLoomy');

    expect(models.map((m) => m.id), ['Kimi-k2.6', 'auto']);
    expect(models.first.name, 'Kimi k2.6');
  });

  test('模型目录拉取失败时回落静态目录', () async {
    adapter.scripts['/api/v1/models'] = [
      (500, {'code': '999999', 'desc': 'boom'}),
    ];

    final models = await auth.fetchModelsForProvider('pLoomy');

    expect(models.map((m) => m.id), contains('auto'));
    expect(models.length, 10);
  });

  test('网关请求头：token + Authorization 双头，且 charset=utf-8', () {
    final headers = LoomyAuthService.requestHeadersForTest('Bearer abc');

    expect(headers['token'], 'abc');
    expect(headers['Authorization'], 'Bearer abc');
    expect(headers['Content-Type'], 'application/json;charset=utf-8');
    // 显式移除 Gemini 形态的旧头，避免串用
    expect(headers.containsKey('x-goog-api-key'), isTrue);
    expect(headers['x-goog-api-key'], isNull);
  });

  test('思考档折叠：只留 low/medium/high，未知档删掉', () {
    final body = <String, dynamic>{
      'reasoning_effort': 'minimal',
      'reasoning': {'effort': 'max'},
    };

    expect(LoomyAuthService.foldReasoning(body), isTrue);
    expect(body['reasoning_effort'], 'low');
    expect(body['reasoning'], {'effort': 'high'});

    final off = <String, dynamic>{'reasoning_effort': 'none'};
    expect(LoomyAuthService.foldReasoning(off), isTrue);
    expect(off.containsKey('reasoning_effort'), isFalse);
  });

  test('旧版 DeepSeek 的 data-URI 图片改写成 <image_base64> 标记', () {
    final body = <String, dynamic>{
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAAA'},
            },
          ],
        },
      ],
    };

    expect(LoomyAuthService.rewriteImagesToTags(body), 1);

    final content = (body['messages'] as List).first['content'] as List;
    expect(content.length, 1);
    expect(content.first['type'], 'text');
    expect(
      content.first['text'],
      '看图\n<image_base64>data:image/png;base64,AAAA</image_base64>',
    );
  });

  test('DeepSeek-V4.1-Flash 收 image_url，不做标记改写', () {
    expect(LoomyAuthService.prefersTagFormat('deepseek-v4-flash-0731'), isTrue);
    expect(LoomyAuthService.prefersTagFormat('DeepSeek-V4.1-Flash'), isFalse);
    expect(LoomyAuthService.prefersTagFormat('Kimi-k2.6'), isFalse);
  });

  test('手机号规范化：去空格/横线与 +86 前缀', () {
    expect(LoomyAuthService.normalizePhone('138 0013 8000'), '13800138000');
    expect(LoomyAuthService.normalizePhone('+8613800138000'), '13800138000');
    expect(LoomyAuthService.normalizePhone('8613800138000'), '13800138000');
    expect(LoomyAuthService.normalizePhone('12800138000'), isNull);
    expect(LoomyAuthService.maskPhone('13800138000'), '138****8000');
    expect(LoomyAuthService.maskPhone('12345'), isEmpty);
  });
}

class _Call {
  final String path;
  final Map<String, dynamic> body;
  final String bodyString;
  final Map<String, String> headers;

  const _Call({
    required this.path,
    required this.body,
    required this.bodyString,
    required this.headers,
  });
}

class _LoomyAdapter implements HttpClientAdapter {
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
    // 登录链路按「实际发出的字节」签名，发的是已序列化的字符串
    final bodyString = data is String ? data : (data == null ? '' : jsonEncode(data));
    final body = bodyString.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(bodyString) as Map);
    calls.add(
      _Call(
        path: path,
        body: body,
        bodyString: bodyString,
        headers: {
          for (final entry in options.headers.entries)
            if (entry.value != null) entry.key: entry.value.toString(),
        },
      ),
    );
    final script = scripts.entries
        .where(
          (entry) => path.endsWith(entry.key) || path.startsWith(entry.key),
        )
        .map((entry) => entry.value)
        .firstOrNull;
    if (script == null) {
      return _json(200, {'code': '000000', 'data': <String, dynamic>{}});
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
