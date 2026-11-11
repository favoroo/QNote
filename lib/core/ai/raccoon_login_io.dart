import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'raccoon_login_types.dart';

/// 启动商汤小浣熊的浏览器回环登录
///
/// 授权页会把浏览器送回 `http://127.0.0.1:<随机端口>/auth/callback?code=...`，
/// 因此这里临时监听本机回环。与 magpie 的实现保持一致：
/// - `state` 必须是 64 位 hex；
/// - 只接受 host、路径、state 都匹配的 GET 回调；
/// - 回调页只显示成功/失败文案，不把授权码回显到页面；
/// - [onCode] 不为空时先完成换取再回页面，换取失败回 502 并让 [code] 抛出。
Future<RaccoonLoopbackLogin> startRaccoonLoopbackLogin({
  Duration timeout = const Duration(minutes: 10),
  Future<void> Function(String code)? onCode,
}) async {
  final state = _randomHex(32);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = '127.0.0.1:${server.port}';
  final completer = Completer<String>();
  var settled = false;
  Timer? timer;
  StreamSubscription<HttpRequest>? subscription;

  Future<void> finish(FutureOr<void> Function() action) async {
    if (settled) return;
    settled = true;
    timer?.cancel();
    try {
      await action();
    } finally {
      try {
        await subscription?.cancel();
      } catch (_) {}
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  void succeed(String code) {
    if (!completer.isCompleted) completer.complete(code);
  }

  void fail(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }

  subscription = server.listen((request) async {
    final response = request.response;
    Future<void> reply(int status, String text) async {
      response.statusCode = status;
      response.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.write(text);
      await response.close();
    }

    // 换取阶段用户可能已经关掉页面或取消登录：这时回报失败是常态，不该冒泡成未捕获异常
    Future<void> replyQuietly(int status, String text) async {
      try {
        await reply(status, text);
      } catch (_) {
        // 连接已断开，忽略
      }
    }

    if (request.method != 'GET') {
      await reply(405, 'Method not allowed');
      return;
    }
    if (request.headers.value(HttpHeaders.hostHeader) != origin || request.uri.path != '/auth/callback') {
      await reply(404, 'Not found');
      return;
    }
    final stateValues = request.uri.queryParametersAll['state'] ?? const [];
    if (stateValues.length != 1 || stateValues.first != state) {
      await reply(400, '回调不属于本次登录，请回原授权页重试。');
      return;
    }
    if (settled) {
      await reply(409, '本次回调已处理，请回 QNote 查看结果。');
      return;
    }
    final error = request.uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      final description = request.uri.queryParameters['error_description'] ?? error;
      await reply(400, '登录未获授权，请回 QNote 重新登录。');
      await finish(() => fail(StateError('授权被拒绝：$description')));
      return;
    }
    final codes = request.uri.queryParametersAll['code'] ?? const [];
    final code = codes.length == 1 ? codes.first.trim() : '';
    if (code.isEmpty || code.length > 4096) {
      await reply(400, '回调缺少授权码，请回原授权页重试。');
      return;
    }
    // 先换取再回页面：换取失败时浏览器不能显示「登录成功」，
    // 否则用户会以为已经登录，回到 App 却看到报错
    try {
      await onCode?.call(code);
    } catch (e) {
      if (!settled) {
        await replyQuietly(502, '登录未完成，请回 QNote 查看错误并重试。');
      }
      await finish(() => fail(e));
      return;
    }
    if (!settled) {
      await replyQuietly(200, '小浣熊登录成功，可关闭此页回 QNote。');
    }
    await finish(() => succeed(code));
  });

  timer = Timer(timeout, () {
    finish(() => fail(TimeoutException('小浣熊登录超时，请重新登录')));
  });

  final url = Uri.https('xiaohuanxiong.com', '/code/authorize', {
    'login_source': 'desktop',
    'appname': '办公小浣熊客户端',
    'state': state,
    'desktop_callback': 'loopback',
    'redirect': 'http://$origin/auth/callback',
  });

  return RaccoonLoopbackLogin(
    url: url.toString(),
    code: completer.future,
    cancel: () {
      finish(() => fail(StateError('登录已取消')));
    },
  );
}

String _randomHex(int bytes) {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
