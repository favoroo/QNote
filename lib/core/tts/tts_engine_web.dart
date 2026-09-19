import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'tts_exception.dart';

/// Web 端 TTS 引擎实现：Edge 在线合成不可用（flutter_edge_tts 依赖 dart:io），
/// 全部走浏览器自带 speechSynthesis（音色跟随浏览器/系统，中文通常有可用声源）。
const bool kOnlineSynthesisSupportedImpl = false;

Future<Uint8List> synthesizeOnlineImpl(
  String text, {
  required String voice,
  required double rate,
}) async {
  throw const TtsException(
    'unsupported_platform',
    'Web 端不支持在线语音合成，请使用系统语音朗读',
  );
}

/// 浏览器 speechSynthesis 朗读，阻塞至朗读完成（onend/onerror 回调驱动）
Future<void> systemSpeakImpl(String text, {required double rate}) async {
  final synth = web.window.speechSynthesis;
  if (synth.isUndefinedOrNull) {
    throw const TtsException(
      'unsupported_platform',
      '当前浏览器不支持语音朗读（speechSynthesis 不可用）',
    );
  }
  // 先清掉可能残留的队列，避免新语句不播
  synth.cancel();

  final utterance = web.SpeechSynthesisUtterance(text)
    ..lang = 'zh-CN'
    ..rate = rate.clamp(0.1, 10.0).toDouble()
    ..pitch = 1.0
    ..volume = 1.0;

  final completer = Completer<void>();
  utterance.onend = ((web.Event _) {
    if (!completer.isCompleted) completer.complete();
  }).toJS;
  utterance.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        const TtsException('speech_failed', '浏览器语音朗读失败'),
      );
    }
  }).toJS;

  synth.speak(utterance);
  await completer.future;
}

Future<void> systemStopImpl() async {
  web.window.speechSynthesis?.cancel();
}
