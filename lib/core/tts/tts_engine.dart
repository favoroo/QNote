/// 平台 TTS 引擎的条件导入入口。
///
/// Edge 在线合成（flutter_edge_tts）依赖 `dart:io` WebSocket，仅原生端可用；
/// Web 端走浏览器自带 speechSynthesis。平台差异由本文件按条件导入分发，
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
