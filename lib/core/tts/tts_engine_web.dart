import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'edge_tts_client.dart';
import 'tts_exception.dart';

/// Web 端 TTS 引擎实现。
///
/// Edge 在线合成只在 Microsoft Edge 浏览器可用：浏览器不允许改写 WebSocket
/// 握手头的 User-Agent，而微软侧对 UA 不含 `Edg/` 的连接一律返回 403
/// （实测 Chrome/Safari 403，Edge 101），故其余浏览器直接走自带 speechSynthesis。
const bool kOnlineSynthesisSupportedImpl = true;

/// 当前浏览器是否具备直连 Edge 语音服务的条件（UA 含 Edg/ 标记）
bool get _edgeBrowserSupported =>
    web.window.navigator.userAgent.contains('Edg/');

/// Edge 在线合成：返回 mp3 音频字节，失败抛 [TtsException]
Future<Uint8List> synthesizeOnlineImpl(
  String text, {
  required String voice,
  required double rate,
}) async {
  if (!_edgeBrowserSupported) {
    throw const TtsException(
      'unsupported_platform',
      '当前浏览器不支持 Edge 在线语音（仅 Microsoft Edge 可用），已改用设备语音',
    );
  }
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

/// 浏览器 speechSynthesis 朗读，阻塞至朗读完成（onend/onerror 回调驱动）。
///
/// [resetQueue] 只在本场朗读的第一段为 true：浏览器自带朗读队列会自动续播下一段，
/// 分段之间若继续 `cancel()`，后一段就会把正在念的前一段掐掉，只剩最后一句有声。
/// Chrome 上 cancel 紧接 speak 还有丢声竞态，故清场后稍作延迟。
Future<void> systemSpeakImpl(
  String text, {
  required double rate,
  bool resetQueue = true,
}) async {
  final synth = web.window.speechSynthesis;
  if (synth.isUndefinedOrNull) {
    throw const TtsException(
      'unsupported_platform',
      '当前浏览器不支持语音朗读（speechSynthesis 不可用）',
    );
  }
  if (resetQueue) {
    synth.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

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
  web.window.speechSynthesis.cancel();
}
