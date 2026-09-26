import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';

import 'edge_tts_client.dart';
import 'tts_exception.dart';

/// 原生端（Android/iOS/macOS/Windows/Linux）TTS 引擎实现：
/// Edge 在线合成走自研协议层（手动握手覆盖 UA，绕开 dart:io 默认
/// UA 被 WAF 403 的问题），系统 TTS 兜底走 flutter_tts。
const bool kOnlineSynthesisSupportedImpl = true;

/// Edge 在线合成：返回 mp3 音频字节（24kHz 48kbit 单声道）。
/// 接口为非官方协议，任何异常统一包成 [TtsException] 交上层降级。
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

/// 系统 TTS 引擎实例（进程内复用）。
///
/// Android/iOS 上每次新建 `FlutterTts` 都要重新绑定引擎，首帧朗读有概率在
/// 引擎就绪前被丢弃且不报错——正是"点了完全没声音"的形态，故全局复用一个。
FlutterTts? _systemTts;

Future<FlutterTts> _sharedSystemTts() async {
  final existing = _systemTts;
  if (existing != null) return existing;
  final tts = FlutterTts();
  // speak() 等待朗读结束再返回，与在线合成的完成语义对齐
  await tts.awaitSpeakCompletion(true);
  _systemTts = tts;
  return tts;
}

/// 系统 TTS 朗读（flutter_tts），阻塞至朗读完成，便于上层复位播放状态。
///
/// 语速映射：flutter_tts 的 setSpeechRate 在 Android/iOS 上均为 0.0~1.0，
/// 0.5 约等于正常语速，故按倍率×0.5 换算。上限须大于最长朗读时长
/// （分段后单段只有一两分钟量级），超时不再被当作成功而是明确报错。
///
/// [resetQueue] 只在分段朗读的首段为 true：先掐掉可能残留的上一场朗读。
/// 分段之间靠 `awaitSpeakCompletion(true)` 天然串行排队，无需也不应再 stop。
Future<void> systemSpeakImpl(
  String text, {
  required double rate,
  bool resetQueue = true,
}) async {
  final tts = await _sharedSystemTts();
  if (resetQueue) await tts.stop().catchError((_) {});
  await tts.setLanguage('zh-CN');
  await tts.setSpeechRate((rate * 0.5).clamp(0.0, 1.0));
  await tts.setPitch(1.0);
  await tts.setVolume(1.0);
  try {
    final result = await tts.speak(text).timeout(const Duration(seconds: 300));
    if (result is int && result < 0) {
      throw const TtsException(
        'speech_failed',
        '系统语音朗读失败（设备可能没有可用的中文语音引擎）',
      );
    }
  } on TtsException {
    rethrow;
  } on TimeoutException {
    // 超时意味着引擎从未回调（未安装/未就绪），静默当成成功会让用户只听到无声
    await tts.stop().catchError((_) {});
    throw const TtsException(
      'speech_timeout',
      '系统语音无响应：设备可能未安装中文语音引擎',
    );
  } catch (e) {
    throw TtsException('speech_failed', '系统语音朗读失败：$e');
  }
}

Future<void> systemStopImpl() async {
  try {
    // 必须停掉真正在朗读的那个实例：新建 FlutterTts().stop() 打到的是空引擎
    await _systemTts?.stop();
  } catch (_) {
    // 停止失败无需上报：下一次朗读会重新配置引擎
  }
}
