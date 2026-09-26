import 'dart:async';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/tts/speech_segments.dart';

/// 朗读通道对外的操作面（生产实现是 `TtsPlayer`，单测注入假实现）。
///
/// 方法名与 `TtsPlayer` 保持一致，让它直接 `implements SpeechSink` 即可，
/// 不必再多一层只有转调的适配器。
abstract interface class SpeechSink {
  /// 开启一场分段朗读
  void beginSpeech(String messageId, {required String voice, required double rate});

  /// 追加一段已清洗的可朗读文本
  void enqueueSpeech(String text);

  /// 声明本场没有更多片段
  void finishSpeech();

  /// 作废本场朗读并复位状态
  Future<void> stop();

  /// 把临时 key 换成本轮最终消息的 key
  void retagMessage(String oldKey, String newKey);
}

/// 把小Q的流式正文增量接成一场分段朗读，供两条对话链路共用。
///
/// 本类只处理时序与策略，不碰音频与网络：
/// - 配置读取是异步的，而 `contentDelta` 是 token 级高频同步路径，
///   所以配置未到位前把已切好的段暂扣下来，到位后一次性放行；
/// - Agent 每一轮 `turnStart` 都会清空正文缓冲（界面同样只保留最后一轮），
///   朗读必须跟着作废，否则会出现"念半截又从头念"；
/// - 自动朗读开关关闭时全程不触碰朗读通道。
class StreamingSpeechSession {
  /// [settings] 由调用方提供（通常是 `QVoiceConfig.instance.get()`），
  /// 提前预热可让第一段几乎不等待就能开口。
  StreamingSpeechSession({
    required SpeechSink sink,
    required Future<QVoiceSettings> settings,
    required String keyPrefix,
  }) : _sink = sink,
       _keyPrefix = keyPrefix {
    unawaited(
      settings.then(_onSettings).catchError((Object _) {
        // 读配置失败就别念了：此时开口只可能用错音色，静默比念错更好
        _closed = true;
      }),
    );
  }

  /// 暂扣段数上限：配置迟迟读不到时放弃本场，避免攒出一大段"迟到语音炸弹"
  static const int _maxHeldSegments = 12;

  final SpeechSink _sink;
  final String _keyPrefix;
  final SpeechSegmentBuilder _builder = SpeechSegmentBuilder();

  final List<String> _held = [];

  String? _voice;
  double _rate = 1.0;
  bool _ready = false;
  bool _opened = false;
  bool _closed = false;
  int _turnNonce = 0;
  String _messageKey = '';

  /// 本场是否已经开口（上层可据此判断"没开口就不必打断正在播的上一条"）
  bool get hasStartedSpeaking => _opened;

  void _onSettings(QVoiceSettings settings) {
    if (_closed) return;
    if (!settings.autoRead) {
      _closed = true;
      _held.clear();
      return;
    }
    _voice = settings.voice;
    _rate = settings.rate;
    _ready = true;
  }

  /// 正文流式增量到达。
  void onContentDelta(String delta) {
    if (_closed) return;
    _emit(_builder.feed(delta));
  }

  /// 新一轮开始：上一轮的正文会被清空，朗读同样作废。
  void onTurnStart() {
    _builder.reset();
    _held.clear();
    _turnNonce++;
    if (!_opened) return;
    _opened = false;
    unawaited(_sink.stop());
  }

  /// 本轮答复已定稿：把未满门槛的尾巴念完，并把 key 换成正式消息 key 让按钮对上。
  ///
  /// [finalMessageKey] 为 `TtsPlayer.messageKeyOf(reply)`；短回复在流式期间没攒够
  /// 一段，会在这里才第一次开口。
  void onFinish(String finalMessageKey) {
    if (_closed) return;
    _emit(_builder.finish());
    if (!_opened) return;
    _sink.retagMessage(_messageKey, finalMessageKey);
    _sink.finishSpeech();
    _opened = false;
  }

  /// 任务中止、报错或界面已不属于本会话：立刻收声，且本场不再重新开口。
  void onAbort() {
    _closed = true;
    _builder.reset();
    _held.clear();
    if (!_opened) return;
    _opened = false;
    unawaited(_sink.stop());
  }

  /// 把切好的片段送进朗读通道，必要时先补开一场。
  void _emit(List<String> segments) {
    if (_closed || segments.isEmpty) return;
    if (!_ready) {
      _held.addAll(segments);
      if (_held.length > _maxHeldSegments) {
        _closed = true;
        _held.clear();
      }
      return;
    }

    if (!_opened) {
      _opened = true;
      _messageKey = '$_keyPrefix#$_turnNonce';
      _sink.beginSpeech(_messageKey, voice: _voice!, rate: _rate);
      final held = List<String>.of(_held);
      _held.clear();
      for (final segment in held) {
        _sink.enqueueSpeech(segment);
      }
    }
    for (final segment in segments) {
      _sink.enqueueSpeech(segment);
    }
  }
}
