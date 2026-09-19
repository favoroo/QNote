import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'edge_tts_client.dart';
import 'tts_exception.dart';

/// Web 端 TTS 引擎实现：浏览器标准 WebSocket 可直连 Edge TTS
/// （UA 由浏览器决定，不含 Dart 特征，无需手动握手），
/// 仅当在线合成失败时降级到浏览器自带 speechSynthesis。
const bool kOnlineSynthesisSupportedImpl = true;

/// Edge 在线合成：返回 mp3 音频字节，失败抛 [TtsException]
Future<Uint8List> synthesizeOnlineImpl(
  String text, {
  required String voice,
  required double rate,
}) async {
  try {
    return await EdgeTtsClient.synthesize(
      text: text,
      voice: voice,
      rate: rate,
    );
  } on TtsException {
    rethrow;
  } catch (e) {
    throw TtsException('synthesis_failed', '在线语音合成失败：$e');
  }
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
  // 先清掉可能残留的队列，避免新语句不播；
  // Chrome 上 cancel 后立即 speak 存在丢声竞态，稍作延迟规避
  synth.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 60));

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
