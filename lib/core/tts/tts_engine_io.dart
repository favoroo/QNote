import 'dart:typed_data';

import 'package:flutter_edge_tts/flutter_edge_tts.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'tts_exception.dart';

/// 原生端（Android/iOS/macOS/Windows/Linux）TTS 引擎实现：
/// Edge 在线合成走 flutter_edge_tts（dart:io WebSocket），
/// 系统 TTS 兜底走 flutter_tts。
const bool kOnlineSynthesisSupportedImpl = true;

/// Edge 在线合成：返回 mp3 音频字节（24kHz 96kbps 单声道）。
///
/// 每次请求新建实例：音色/语速随调用变化，实例内部持有连接状态，按次
/// 创建最省心；接口为非官方协议，任何异常统一包成 [TtsException] 交上层降级。
Future<Uint8List> synthesizeOnlineImpl(
  String text, {
  required String voice,
  required double rate,
}) async {
  final tts = FlutterEdgeTts(voice: voice);
  try {
    final result = await tts.synthesize(
      text,
      prosody: EdgeTtsProsody(rate: rate.toString()),
    );
    if (result.audioBytes.isEmpty) {
      throw const TtsException('synthesis_failed', '在线语音合成返回了空音频');
    }
    return result.audioBytes;
  } on TtsException {
    rethrow;
  } catch (e) {
    throw TtsException('synthesis_failed', '在线语音合成失败：$e');
  }
}

/// 系统 TTS 朗读（flutter_tts），阻塞至朗读完成，便于上层复位播放状态。
///
/// 语速映射：flutter_tts 的 setSpeechRate 在 Android/iOS 上均为 0.0~1.0，
/// 0.5 约等于正常语速，故按倍率×0.5 换算。
Future<void> systemSpeakImpl(String text, {required double rate}) async {
  final tts = FlutterTts();
  await tts.setLanguage('zh-CN');
  await tts.setSpeechRate((rate * 0.5).clamp(0.0, 1.0));
  await tts.setPitch(1.0);
  await tts.setVolume(1.0);
  // speak() 等待朗读完成再返回，与在线合成的完成语义对齐
  await tts.awaitSpeakCompletion(true);
  try {
    final result = await tts.speak(text);
    if (result is int && result < 0) {
      throw const TtsException('speech_failed', '系统语音朗读失败');
    }
  } catch (e) {
    if (e is TtsException) rethrow;
    throw TtsException('speech_failed', '系统语音朗读失败：$e');
  }
}

Future<void> systemStopImpl() async {
  try {
    await FlutterTts().stop();
  } catch (_) {
    // 停止失败无需上报：下一次朗读前会重新初始化引擎
  }
}
