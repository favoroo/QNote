import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'edge_ws.dart';
import 'tts_exception.dart';

/// Web 端 Edge TTS WebSocket 传输实现（浏览器标准 WebSocket）。
///
/// 浏览器不允许自定义握手头，UA 与 Origin 均由浏览器决定：Origin 不参与校验，
/// 但微软侧要求 UA 含 `Edg/`，因此只有 Edge 浏览器能握手成功（可用性判定见
/// `tts_engine_web.dart`）。
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

  // 单消费者、非 broadcast：握手后立即挂载 onmessage，而调用方要到发出
  // speech.config/ssml 两帧之后才开始监听，broadcast 会把这段无监听期内的
  // 事件直接丢弃（首帧音频丢失）；普通控制器的缓冲队列可避免
  final _controller = StreamController<EdgeWsFrame>();

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
