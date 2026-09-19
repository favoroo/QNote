import 'edge_ws.dart';

/// WS 传输兜底 stub：仅在 dart.library.io 与 dart.library.js_interop 均不可用的
/// 环境参与编译（正常构建不会走到），与 io/web 实现保持同一顶层 API 形状。
Future<EdgeWsConnection> connectEdgeWsImpl(Uri uri, Duration timeout) async {
  throw const TtsException('unsupported_platform', '当前平台不支持语音合成');
}
