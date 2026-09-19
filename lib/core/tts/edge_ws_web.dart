import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'edge_ws.dart';
import 'tts_exception.dart';

/// Web 端 Edge TTS WebSocket 传输实现（浏览器标准 WebSocket）。
///
/// 浏览器不允许自定义握手头（UA/Origin 由浏览器决定，不含 Dart 特征，
/// WAF 可正常放行），因此无需手动握手。
Future<EdgeWsConnection> connectEdgeWsImpl(Uri uri, Duration timeout) async {
  final ws = web.WebSocket(uri.toString());
  ws.binaryType = 'arraybuffer';

  final opened = Completer<bool>();
  final failed = Completer<bool>();
  ws.onopen = ((web.Event _) {
    if (!opened.isCompleted) opened.complete(true);
  }).toJS;
  ws.onerror = ((web.Event _) {
    if (!failed.isCompleted) failed.complete(false);
  }).toJS;

  final openedOk = await Future.any([opened.future, failed.future])
      .timeout(timeout, onTimeout: () {
    ws.close();
    throw const TtsException('handshake_failed', '语音服务连接超时');
  });
  if (!openedOk) {
    throw const TtsException('handshake_failed', '语音服务连接被拒绝');
  }

  return _WebEdgeWsConnection(ws);
}

class _WebEdgeWsConnection implements EdgeWsConnection {
  final web.WebSocket _ws;
  final _controller = StreamController<EdgeWsFrame>.broadcast();

  _WebEdgeWsConnection(this._ws) {
    _ws.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSArrayBuffer>()) {
        _controller.add(
          EdgeWsBinaryFrame((data as JSArrayBuffer).toDart.asUint8List()),
        );
      } else if (data.isA<JSString>()) {
        _controller.add(EdgeWsTextFrame((data as JSString).toDart));
      }
    }).toJS;
    _ws.onclose = ((web.CloseEvent _) {
      if (!_controller.isClosed) _controller.close();
    }).toJS;
    _ws.onerror = ((web.Event _) {
      if (!_controller.isClosed) {
        _controller.addError(
          const TtsException('connection_error', '语音服务连接中断'),
        );
      }
    }).toJS;
  }

  @override
  Stream<EdgeWsFrame> get frames => _controller.stream;

  @override
  void sendText(String data) => _ws.send(data.toJS);

  @override
  Future<void> close() async {
    _ws.close();
    if (!_controller.isClosed) await _controller.close();
  }
}
