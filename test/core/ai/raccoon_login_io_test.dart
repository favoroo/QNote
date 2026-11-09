import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/raccoon_login.dart';

/// 浏览器回环登录的本机服务（Android/iOS/桌面共用的关键链路）
void main() {
  test('回调带正确 state 时返回授权码，并生成 64 位 hex state', () async {
    final login = await startRaccoonLoopbackLogin(
      timeout: const Duration(seconds: 5),
    );
    final authorize = Uri.parse(login.url);
    expect(authorize.queryParameters['desktop_callback'], 'loopback');
    final state = authorize.queryParameters['state']!;
    expect(state.length, 64);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(state), isTrue);

    final redirect = Uri.parse(authorize.queryParameters['redirect']!);
    expect(redirect.host, '127.0.0.1');
    expect(redirect.path, '/auth/callback');

    final client = HttpClient();
    final request = await client.getUrl(
      redirect.replace(queryParameters: {'code': 'auth-code-1', 'state': state}),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    client.close(force: true);

    expect(await login.code, 'auth-code-1');
  });

  test('state 不匹配的回调被拒绝，登录继续等待', () async {
    final login = await startRaccoonLoopbackLogin(
      timeout: const Duration(seconds: 5),
    );
    final authorize = Uri.parse(login.url);
    final redirect = Uri.parse(authorize.queryParameters['redirect']!);

    final client = HttpClient();
    final request = await client.getUrl(
      redirect.replace(queryParameters: {'code': 'stolen', 'state': '0' * 64}),
    );
    final response = await request.close();
    expect(response.statusCode, 400);
    await response.drain<void>();

    // 错误回调不能结束本次登录：随后用正确 state 仍然成功
    final state = authorize.queryParameters['state']!;
    final good = await client.getUrl(
      redirect.replace(queryParameters: {'code': 'ok', 'state': state}),
    );
    final goodResponse = await good.close();
    expect(goodResponse.statusCode, 200);
    await goodResponse.drain<void>();
    client.close(force: true);

    expect(await login.code, 'ok');
  });

  test('cancel 结束等待并抛出取消错误', () async {
    final login = await startRaccoonLoopbackLogin(
      timeout: const Duration(seconds: 5),
    );
    final expectation = expectLater(login.code, throwsA(isA<StateError>()));
    login.cancel();
    await expectation;
  });
}