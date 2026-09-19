/// 平台 TTS 引擎的条件导入入口。
///
/// Edge 在线合成走自研协议层（见 `edge_tts_client.dart`）：原生端手动握手
/// 覆盖 User-Agent（dart:io 的 `WebSocket.connect` 追加 Dart UA 会被微软
/// WAF 403），Web 端浏览器 WebSocket 天然放行——因此三端均可在线合成；
/// 合成失败时降级到平台系统语音（原生 flutter_tts / 浏览器 speechSynthesis）。
/// 各平台实现文件（tts_engine_io / tts_engine_web / tts_engine_stub）暴露
/// 同一套顶层函数与同名常量（仿 image_saver 的鸭子类型模式）。
library;

import 'dart:typed_data';

import 'tts_exception.dart';
import 'tts_engine_stub.dart'
    if (dart.library.js_interop) 'tts_engine_web.dart'
    if (dart.library.io) 'tts_engine_io.dart';

export 'tts_exception.dart';

/// 当前平台是否支持 Edge 在线合成（Web 为 false，直接走系统语音）
const bool kOnlineSynthesisSupported = kOnlineSynthesisSupportedImpl;

/// 在线合成：返回 mp3 音频字节，失败抛 [TtsException]
Future<Uint8List> synthesizeOnline(
  String text, {
  required String voice,
  required double rate,
}) => synthesizeOnlineImpl(text, voice: voice, rate: rate);

/// 系统语音直接朗读（阻塞至朗读完成），失败抛 [TtsException]
Future<void> systemSpeak(String text, {required double rate}) =>
    systemSpeakImpl(text, rate: rate);

/// 停止系统语音朗读
Future<void> systemStop() => systemStopImpl();
