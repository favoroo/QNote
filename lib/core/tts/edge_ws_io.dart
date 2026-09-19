import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'edge_ws.dart';
import 'tts_exception.dart';

/// 原生端 Edge TTS WebSocket 传输实现。
///
/// 必须[手动完成握手升级]：dart:io 的 `WebSocket.connect` 会把自定义
/// User-Agent 追加在默认 `Dart/x.x (dart:io)` 之后发送（set 语义仅对
/// `HttpClient.userAgent` 属性成立），微软 WAF 检测到该特征一律返回
/// 403。手动握手可让 `HttpClient.userAgent` 覆盖为 Chrome UA。
Future<EdgeWsConnection> connectEdgeWsImpl(Uri uri, Duration timeout) async {
  final client = HttpClient();
  // 覆盖语义：请求头里的 UA 必须用这一入口，绝不能再经 headers 传入
  client.userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';
  client.connectionTimeout = timeout;
  try {
    // HttpClient 不支持 wss scheme，升级握手走 https GET（同一 TLS 端点）
    final httpUri = uri.replace(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
    );
    final request = await client.openUrl('GET', httpUri);
    request.headers.set('Accept', '*/*');
    request.headers.set('Accept-Encoding', 'gzip, deflate, br, zstd');
    request.headers.set('Accept-Language', 'en-US,en;q=0.9');
    request.headers.set('Cache-Control', 'no-cache');
    request.headers.set('Connection', 'Upgrade');
    request.headers.set(
      'Cookie',
      'muid=${_randomHex(16).toUpperCase()};',
    );
    request.headers.set(
      'Origin',
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    );
    request.headers.set('Pragma', 'no-cache');
    request.headers.set(
      'Sec-WebSocket-Key',
      base64.encode(_randomBytes(16)),
    );
    request.headers.set('Sec-WebSocket-Version', '13');
    request.headers.set('Upgrade', 'websocket');

    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.switchingProtocols) {
      final status = response.statusCode;
      await response.drain<void>().catchError((_) {});
      throw TtsException(
        'handshake_failed',
        '语音服务握手被拒绝（HTTP $status）',
      );
    }

    // 101 响应头已消费，剩余的裸 socket 就是纯 WS 通道
    final socket = await response.detachSocket();
    final ws = WebSocket.fromUpgradedSocket(socket, serverSide: false);
    return _IoEdgeWsConnection(ws, client);
  } on TtsException {
    client.close(force: true);
    rethrow;
  } catch (e) {
    client.close(force: true);
    throw TtsException('handshake_failed', '语音服务连接失败：$e');
  }
}

class _IoEdgeWsConnection implements EdgeWsConnection {
  final WebSocket _ws;
  final HttpClient _client;

  _IoEdgeWsConnection(this._ws, this._client);

  @override
  Stream<EdgeWsFrame> get frames => _ws.map((data) {
        if (data is String) return EdgeWsTextFrame(data);
        if (data is Uint8List) return EdgeWsBinaryFrame(data);
        if (data is List<int>) return EdgeWsBinaryFrame(data);
        throw TtsException('unknown_frame', '语音服务返回了未知帧类型');
      });

  @override
  void sendText(String data) => _ws.add(data);

  @override
  Future<void> close() async {
    await _ws.close().catchError((_) {});
    _client.close();
  }
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List.generate(length, (_) => random.nextInt(256)),
  );
}

String _randomHex(int bytesLength) =>
    _randomBytes(bytesLength)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
