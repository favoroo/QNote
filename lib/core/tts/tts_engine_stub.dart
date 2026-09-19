import 'dart:typed_data';

import 'tts_exception.dart';

/// TTS 引擎兜底 stub：仅在 dart.library.io 与 dart.library.js_interop 均不可用的
/// 环境参与编译（正常构建不会走到），保持与 io/web 实现相同的顶层 API 形状。
const bool kOnlineSynthesisSupportedImpl = false;

Future<Uint8List> synthesizeOnlineImpl(
  String text, {
  required String voice,
  required double rate,
}) async {
  throw const TtsException('unsupported_platform', '当前平台不支持语音合成');
}

Future<void> systemSpeakImpl(String text, {required double rate}) async {
  throw const TtsException('unsupported_platform', '当前平台不支持语音朗读');
}

Future<void> systemStopImpl() async {}
