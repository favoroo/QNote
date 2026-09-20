// just_audio 播放内存字节的官方途径是 StreamAudioSource（标注 experimental，
// 但已是字节播放的既定方案）；确认稳定前集中忽略该告警
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/tts/tts_service.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 语音朗读的播放状态
enum TtsPlaybackStatus { idle, synthesizing, playing }

/// 当前朗读任务的状态快照（同一时刻最多一个朗读任务）
class TtsPlaybackState {
  /// 正在处理/播放的消息标识（[TtsPlayer.messageKeyOf] 生成；试听为专用前缀）
  final String? messageId;

  final TtsPlaybackStatus status;

  /// 最近一次失败的中文描述（供 UI Toast），成功/停止时为 null
  final String? error;

  const TtsPlaybackState({
    this.messageId,
    this.status = TtsPlaybackStatus.idle,
    this.error,
  });

  static const TtsPlaybackState idle = TtsPlaybackState();
}

/// 小Q语音回复播放器：合成（Edge 失败降级系统语音）+ 播放 + 状态发布。
///
/// 全局单朗读通道：新任务开始或 [stop] 时旧任务作废（代际号守卫），
/// 事件完成回调先校验代际，避免旧任务把新任务的状态复位成空闲。
class TtsPlayer extends Notifier<TtsPlaybackState> {
  static const int _maxCacheEntries = 20;

  AudioPlayer? _player;
  StreamSubscription? _playerSub;
  StreamSubscription? _playerErrorSub;
  int _generation = 0;

  /// 正在播放（已把状态置为 playing）的那次任务代际，复位后清空。
  ///
  /// 完成信号只来自播放器的 `processingState == completed`，而 just_audio 播完
  /// 不会自己把 `playing` 置回 false，光看状态流无法区分"这条读完了"和"上一条
  /// 的迟到事件"，故用代际号把复位精确归位到当前任务。
  int? _playingGeneration;

  /// 播放器最近一次载入/播放失败的描述。
  ///
  /// just_audio 的 `play()` 不会因源载入失败而抛异常（错误只在事件流里报告），
  /// 不主动收集就会出现"无声也无报错、还错过系统语音兜底"的静默失败。
  String? _playbackErrorMessage;

  /// 合成结果内存缓存（digest → mp3 bytes），重听同一条回复免重复合成
  final Map<String, Uint8List> _cache = {};

  @override
  TtsPlaybackState build() => TtsPlaybackState.idle;

  /// 消息的稳定播放标识：角色 + 正文 md5。
  ///
  /// 消息模型无 id 字段，且自动朗读与气泡渲染拿到的可能是内容相同的
  /// 不同对象（时间戳会有毫秒级差异），按内容摘要定 key 才能保证
  /// 按钮状态精确对齐，点击"停止"不会因 key 不匹配被误判成重新朗读。
  static String messageKeyOf(ChatMessage message) =>
      'msg_${message.role}_${md5.convert(utf8.encode(message.content))}';

  /// 气泡按钮入口：同一消息再次点击时停止，否则开始朗读
  Future<void> toggleMessage(ChatMessage message) async {
    final key = messageKeyOf(message);
    final current = state;
    if (current.messageId == key && current.status != TtsPlaybackStatus.idle) {
      await stop();
      return;
    }
    await speakMessage(key, message.content);
  }

  /// 朗读一段文本：自动读取语音配置；[voiceOverride]/[rateOverride] 供试听覆盖。
  ///
  /// 全程抛错时状态复位为空闲并携带 [TtsPlaybackState.error]，由 UI 层提示。
  Future<void> speakMessage(
    String messageId,
    String text, {
    String? voiceOverride,
    double? rateOverride,
  }) async {
    final cleanText = TtsService.cleanSpeechText(text);
    if (cleanText.isEmpty) {
      state = const TtsPlaybackState(
        error: '没有可朗读的文字内容',
      );
      return;
    }

    // 打断上一个任务：代际号自增使其所有在途回调失效
    await stop();
    final gen = ++_generation;
    state = TtsPlaybackState(
      messageId: messageId,
      status: TtsPlaybackStatus.synthesizing,
    );

    final settings = await QVoiceConfig.instance.get();
    final voice = voiceOverride ?? settings.voice;
    final rate = rateOverride ?? settings.rate;

    // 首选 Edge 在线合成（三端均可用；选了系统语音则直接跳过在线通道），
    // 失败记录原因后降级系统语音
    String? onlineFailureReason;
    final useSystemVoice = voice == QVoiceConfig.systemVoiceId;
    if (useSystemVoice) {
      LoggerService.instance.logAI('TTS 使用系统语音（用户指定，跳过在线合成）');
    } else if (kOnlineSynthesisSupported) {
      try {
        final bytes = await _synthesizedBytes(cleanText, voice, rate);
        if (gen != _generation) return;
        await _playBytes(gen, bytes);
        return;
      } on TtsException catch (e) {
        if (gen != _generation) return;
        onlineFailureReason = e.message;
        LoggerService.instance.logAI('Edge TTS 降级系统语音: ${e.message}');
      } catch (e) {
        if (gen != _generation) return;
        onlineFailureReason = '$e';
        LoggerService.instance.logAI('Edge TTS 降级系统语音: $e');
      }
    }

    try {
      // 走系统语音后 just_audio 不再参与本次朗读，摘掉播放器事件的复位授权，
      // 避免降级前那次播放的迟到 completed 把系统语音的状态提前打回空闲
      _playingGeneration = null;
      state = TtsPlaybackState(
        messageId: messageId,
        status: TtsPlaybackStatus.playing,
      );
      await TtsService.speakNative(text: cleanText, rate: rate);
      if (gen != _generation) return;
      state = TtsPlaybackState(messageId: messageId);
    } catch (e) {
      if (gen != _generation) return;
      // 把两段失败原因都带给用户，便于区分网络问题与设备能力问题
      final fallbackReason = e is TtsException ? e.message : '$e';
      final combined = onlineFailureReason == null
          ? fallbackReason
          : '$onlineFailureReason；系统语音：$fallbackReason';
      state = TtsPlaybackState(error: combined);
    }
  }

  /// 停止当前朗读并复位状态
  Future<void> stop() async {
    _generation++;
    _playingGeneration = null;
    await _player?.stop();
    await TtsService.stopNative();
    state = TtsPlaybackState.idle;
  }

  /// 合成（带缓存），命中缓存时跳过网络请求
  Future<Uint8List> _synthesizedBytes(String text, String voice, double rate) async {
    final digest = md5.convert(utf8.encode('$voice|$rate|$text')).toString();
    final cached = _cache[digest];
    if (cached != null) return cached;
    final bytes = await TtsService.synthesize(text: text, voice: voice, rate: rate);
    _cache.remove(digest);
    _cache[digest] = bytes;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    return bytes;
  }

  /// 用 just_audio 播放 mp3 字节流；完成事件校验代际后复位状态。
  ///
  /// 原生端 `StreamAudioSource` 由 just_audio 的本机回环 HTTP 代理供流，明文被
  /// 系统网络策略拦截时 `play()` 只记录错误不抛异常，因此播放返回后必须核对
  /// 错误事件与处理状态，把失败变成可降级、可提示的异常。
  Future<void> _playBytes(int gen, Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const TtsException('empty_audio', '在线语音合成返回了空音频');
    }
    final player = _ensurePlayer();
    _playbackErrorMessage = null;
    await player.setAudioSource(_BytesAudioSource(bytes));
    if (gen != _generation) return;
    state = TtsPlaybackState(
      messageId: state.messageId,
      status: TtsPlaybackStatus.playing,
    );
    _playingGeneration = gen;
    await player.play();
    if (gen != _generation) return;

    final message = _playbackErrorMessage;
    if (message != null) {
      throw TtsException('playback_failed', '音频播放失败：$message');
    }
    // 未进入任何可播放状态即返回，说明源根本没被播放器接受
    if (player.processingState == ProcessingState.idle) {
      throw const TtsException('playback_failed', '音频未能载入播放器');
    }
    // play() 的 Future 在播完（或被暂停/中断）时才完成，正常情况下复位已由状态流
    // 的 completed 事件触发；这里再兜一次，防止事件与 Future 的先后时序把状态留在
    // playing、朗读按钮卡在停止图标。_onPlaybackFinished 幂等，重复调用无副作用。
    if (player.processingState == ProcessingState.completed || !player.playing) {
      _onPlaybackFinished();
    }
  }

  AudioPlayer _ensurePlayer() {
    if (_player != null) return _player!;
    final player = AudioPlayer();
    _player = player;
    _playerSub = player.playerStateStream.listen((ps) {
      // 播放自然结束（completed）后复位为空闲。stop() 触发的完成因代际号
      // 已自增而被忽略，不会覆盖新任务状态
      if (playbackFinished(ps)) {
        _onPlaybackFinished();
      }
    });
    _playerErrorSub = player.playbackEventStream.listen(
      (event) {
        // Android/iOS 把 ExoPlayer/AVPlayer 的错误码与描述随事件下发
        if (event.errorCode != null) {
          _playbackErrorMessage = event.errorMessage ?? '错误码 ${event.errorCode}';
        }
      },
      // 广播流上单个订阅者出错不影响其它订阅，留痕后继续监听
      onError: (Object e) {
        _playbackErrorMessage = e is PlayerException
            ? (e.message ?? '错误码 ${e.code}')
            : '$e';
      },
      cancelOnError: false,
    );
    _configureAudioSession();
    ref.onDispose(() {
      _playerSub?.cancel();
      _playerErrorSub?.cancel();
      _player?.dispose();
    });
    return player;
  }

  /// 播放器状态是否表示"这一次朗读已经放完"（纯判定，供状态流回调与单测复用）。
  ///
  /// 只看 `processingState`：just_audio 的 `playing` 由 `play()` 置为 true 后，
  /// 要等到 `pause()`/`stop()` 才会回到 false，音频自然播完时它仍是 true。
  /// 若额外要求 `!playing`，完成判定就永远不成立，朗读按钮会卡在停止图标，
  /// 用户得点两下（第一下 stop、第二下才重新朗读）才能恢复。
  static bool playbackFinished(PlayerState ps) =>
      ps.processingState == ProcessingState.completed;

  /// 本次朗读结束：复位为空闲（保留 messageId，让该条按钮回到"朗读"态）
  void _onPlaybackFinished() {
    final gen = _playingGeneration;
    // 代际不匹配说明这是被 stop()/新任务作废的旧播放器事件，忽略以免覆盖新状态
    if (gen == null || gen != _generation) return;
    _playingGeneration = null;
    if (state.status == TtsPlaybackStatus.playing) {
      state = TtsPlaybackState(messageId: state.messageId);
    }
  }

  /// 原生端配置音频会话为语音场景：iOS 默认会话会跟随硬件静音键，
  /// playback 类别下朗读不受静音键影响；Android 上自动暂停其他媒体。
  Future<void> _configureAudioSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
    } catch (_) {
      // 会话配置失败不阻塞朗读：仅影响静音键行为与混音策略
    }
  }
}

final ttsPlaybackProvider =
    NotifierProvider<TtsPlayer, TtsPlaybackState>(TtsPlayer.new);

/// 把内存字节包装成 just_audio 可读的音频源（Android/iOS/Web 通用）
class _BytesAudioSource extends StreamAudioSource {
  final Uint8List bytes;

  _BytesAudioSource(this.bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // 短音频一次性全量返回即可，不支持 range 分段
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: bytes.length,
      contentLength: bytes.length,
      offset: 0,
      stream: Stream.value(bytes),
      contentType: 'audio/mpeg',
    );
  }
}
