import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';

/// 授权码换取的重试语义。
///
/// 浏览器回环登录里授权码是「刚签发就交换」，厂商后端偶发还没把这条码同步到
/// 兑换节点：第一次会返回 `200035` 或空的 2xx，隔一两秒用同一个码再换就能成功。
/// 这正是「网页登录报错、复制同一个回调链接粘贴反而能登录」的根因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RaccoonAuthService auth;
  late _ExchangeAdapter adapter;
  late List<AiAccount> saved;

  setUp(() {
    auth = RaccoonAuthService.instance;
    auth.resetForTest();
    saved = [];
    RaccoonAuthService.accountsLoaderForTest = (_) async => List.of(saved);
    RaccoonAuthService.accountSaverForTest = (account) async {
      saved.removeWhere((item) => item.id == account.id);
      saved.add(account);
    };
    // 重试退避在测试里立即返回，避免每条用例多等 1.6 秒
    RaccoonAuthService.exchangeRetryWaitForTest = (_) async {};
    adapter = _ExchangeAdapter();
    auth.httpClientAdapterForTest = adapter;
  });

  tearDown(() => auth.resetForTest());

  test('授权码还没生效：第一次 200035，自动重试后登录成功', () async {
    adapter.exchangeScript = [
      (
        400,
        {
          'code': 200035,
          'message': 'authorization_code_not_found_error',
          'details': 'authorization code not found',
        }
      ),
      (
        200,
        {
          'code': 0,
          'data': {'access_token': 'access-2', 'refresh_token': 'refresh-2'},
        }
      ),
    ];

    final account = await auth.exchangeCode('pRaccoon', 'code-1');

    expect(adapter.exchangeCalls, 2);
    expect(account.accessToken, 'access-2');
    expect(account.refreshToken, 'refresh-2');
    expect(account.providerId, 'pRaccoon');
    expect(account.phone, '138****8000');
    expect(saved.single.id, account.id);
    expect(adapter.profileCalls, 1);
  });

  test('授权码确实失效：重试到上限后给出可操作提示', () async {
    adapter.exchangeScript = [
      (
        400,
        {
          'code': 200035,
          'message': 'authorization_code_not_found_error',
          'details': 'authorization code not found',
        }
      ),
    ];

    await expectLater(
      auth.exchangeCode('pRaccoon', 'code-used'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '授权码已失效，请重新发起网页登录',
        ),
      ),
    );
    expect(adapter.exchangeCalls, 3);
  });

  test('确定性拒绝（403）不浪费重试次数', () async {
    adapter.exchangeScript = [
      (403, {'code': 900403, 'details': 'forbidden'}),
    ];

    await expectLater(
      auth.exchangeCode('pRaccoon', 'code-1'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('forbidden'),
        ),
      ),
    );
    expect(adapter.exchangeCalls, 1);
  });

  test('2xx 却没有 token：按瞬时异常重试，最终提示带 HTTP 状态', () async {
    adapter.exchangeScript = [
      (200, {'code': 0, 'data': <String, dynamic>{}}),
    ];

    await expectLater(
      auth.exchangeCode('pRaccoon', 'code-1'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '登录失败：HTTP 200',
        ),
      ),
    );
    expect(adapter.exchangeCalls, 3);
  });
}

class _ExchangeAdapter implements HttpClientAdapter {
  /// (HTTP 状态, 响应体)；超出长度后一直用最后一条
  List<(int, Map<String, dynamic>)> exchangeScript = [];
  int exchangeCalls = 0;
  int profileCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/login_with_authorization_code')) {
      exchangeCalls++;
      final index = math.min(exchangeCalls - 1, exchangeScript.length - 1);
      final (status, body) = exchangeScript[index];
      return _json(status, body);
    }
    if (path.endsWith('/user_info')) {
      profileCalls++;
      return _json(200, {
        'code': 0,
        'data': {'phone': '13800138000', 'name': '张三'},
      });
    }
    return _json(404, {'code': 404, 'details': 'not found'});
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