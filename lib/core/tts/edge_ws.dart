/// Edge TTS WebSocket 传输层的条件导入入口。
///
/// 原生端必须手动握手：dart:io 的 `WebSocket.connect` 会把
/// `Dart/x.x (dart:io)` 追加进 User-Agent，微软 WAF 对该特征一律 403
/// （flutter_edge_tts 包即因此失效）。手动用 HttpClient（`userAgent`
/// 属性为覆盖语义）完成 101 升级后以 `WebSocket.fromUpgradedSocket` 包装。
/// Web 端浏览器不允许自定义握手头，走标准 `WebSocket`（UA 由浏览器决定，
/// 不含 Dart 特征，可正常放行）。
///
/// 各平台实现文件暴露同一组顶层函数（鸭子类型，仿 image_saver 模式）：
/// - `Future<EdgeWsConnection> connectEdgeWs(Uri uri, Duration timeout)`
library;

import 'edge_ws_stub.dart'
    if (dart.library.js_interop) 'edge_ws_web.dart'
    if (dart.library.io) 'edge_ws_io.dart';

export 'tts_exception.dart';

/// WS 帧：文本帧（协议控制）或二进制帧（含音频负载）
sealed class EdgeWsFrame {
  const EdgeWsFrame();
}

class EdgeWsTextFrame extends EdgeWsFrame {
  final String text;
  const EdgeWsTextFrame(this.text);
}

class EdgeWsBinaryFrame extends EdgeWsFrame {
  final List<int> bytes;
  const EdgeWsBinaryFrame(this.bytes);
}

/// 已升级的 WebSocket 连接（抽象面，供协议层驱动）
abstract interface class EdgeWsConnection {
  /// 帧流（连接出错或关闭后自动结束）
  Stream<EdgeWsFrame> get frames;

  /// 发送一条文本协议帧
  void sendText(String data);

  /// 关闭连接
  Future<void> close();
}

/// 建立 Edge TTS WebSocket 连接，失败抛 [TtsException]（handshake_failed）
Future<EdgeWsConnection> connectEdgeWs(Uri uri, {Duration timeout = const Duration(seconds: 15)}) =>
    connectEdgeWsImpl(uri, timeout);
