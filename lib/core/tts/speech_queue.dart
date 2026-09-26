import 'dart:async';
import 'dart:typed_data';

/// 一个待播放的朗读片段。
///
/// [audio] 为 null 表示这一段没有可用音频：用户选了系统语音、或在线合成失败
/// （此时 [error] 带上原因，由调用方决定是降级还是终止）。
class SpeechSegment {
  SpeechSegment({
    required this.index,
    required this.text,
    this.audio,
    this.error,
  });

  /// 片段在本场朗读中的序号（0 为首段）
  final int index;

  /// 片段原文（走系统语音时直接念它）
  final String text;

  final Uint8List? audio;
  final Object? error;

  bool get hasAudio => audio != null && audio!.isNotEmpty;
}

/// 分段朗读的调度队列：按入队顺序串行播放，并在播第 N 段时预先合成第 N+1 起的若干段。
///
/// 拆成独立的纯调度类有两个好处：一是「合成领先播放若干段」的游标逻辑与
/// just_audio、Riverpod、网络都无关，可以直接单测；二是策略留在调用方
/// （[SpeechQueue] 只负责顺序与预取，降级还是终止由 `play` 回调决定）。
class SpeechQueue {
  SpeechQueue({
    required Future<Uint8List?> Function(String text) synthesize,
    required Future<void> Function(SpeechSegment segment) play,
    bool Function()? isCancelled,
    this.prefetch = 2,
  }) : _synthesize = synthesize,
       _play = play,
       _isCancelled = isCancelled ?? _neverCancelled;

  static bool _neverCancelled() => false;

  /// 在线合成一段文本；返回 null 表示这一段不产出音频（改念 [SpeechSegment.text]）
  final Future<Uint8List?> Function(String text) _synthesize;

  /// 播放一段。抛错即终止本场并把错误交给 [run] 的调用方。
  final Future<void> Function(SpeechSegment segment) _play;

  /// 本场是否已作废（新一轮朗读、用户点停止、切会话都会让它提前结束）
  final bool Function() _isCancelled;

  /// 领先播放位置几个片段做预取
  final int prefetch;

  final List<String> _texts = [];
  final List<Future<_SynthOutcome>?> _scheduled = [];
  int _playCursor = 0;
  int _synthCursor = 0;
  bool _closed = false;
  Completer<void>? _wake;
  Future<void>? _loop;

  /// 是否还没有任何片段入队（调用方据此判断"还没开口，不必打断正在播的音频"）
  bool get isEmpty => _texts.isEmpty;

  int get length => _texts.length - _playCursor;

  /// 追加一段待朗读文本。播放中调用合法：只入队并推进预取，绝不打断当前段。
  void add(String text) {
    _texts.add(text);
    _scheduled.add(null);
    _pump();
    _wakeUp();
  }

  /// 声明不再有新片段：队列排空后 [run] 自然结束。
  void close() {
    _closed = true;
    _wakeUp();
  }

  /// 作废本场：丢弃未播片段与预取结果（在途合成的结果会被代际守卫忽略）。
  void clear() {
    _texts.clear();
    _scheduled.clear();
    _playCursor = 0;
    _synthCursor = 0;
    _closed = false;
    _wakeUp();
  }

  /// 串行播放直到排空且已 [close]，或被 [SpeechQueue.isCancelled] 作废。
  ///
  /// 重复调用返回同一条循环的 Future：调用方既能发起、也能等待收尾，
  /// 不会因为"已经在跑"而拿到一个假的立即完成信号。
  Future<void> run() => _loop ??= _runLoop();

  Future<void> _runLoop() async {
    while (true) {
      if (_isCancelled()) return;
      if (_playCursor >= _texts.length) {
        if (_closed) return;
        await _waitForMore();
        continue;
      }
      final index = _playCursor;
      final outcome = await _outcomeAt(index);
      if (_isCancelled()) return;
      await _play(
        SpeechSegment(
          index: index,
          text: _texts[index],
          audio: outcome.audio,
          error: outcome.error,
        ),
      );
      _playCursor = index + 1;
      _pump();
    }
  }

  /// 把预取窗口推到播放位置之前 [prefetch] 段。
  void _pump() {
    final limit = _playCursor + prefetch;
    while (_synthCursor < _texts.length && _synthCursor < limit) {
      _scheduled[_synthCursor] ??= _synthesizeQuietly(_texts[_synthCursor]);
      _synthCursor++;
    }
  }

  Future<_SynthOutcome> _outcomeAt(int index) {
    return _scheduled[index] ??= _synthesizeQuietly(_texts[index]);
  }

  /// 合成结果一律包成不抛错的 Future。
  ///
  /// 预取出去的段很可能因为用户中途停止而永远没人 await，若 Future 本身带错误，
  /// Dart 会把它升级为未处理异常并把整个 Isolate 拖崩。
  Future<_SynthOutcome> _synthesizeQuietly(String text) async {
    try {
      return _SynthOutcome(await _synthesize(text));
    } on Object catch (e) {
      return _SynthOutcome.failed(e);
    }
  }

  Future<void> _waitForMore() {
    final waiter = _wake ??= Completer<void>();
    return waiter.future;
  }

  void _wakeUp() {
    final waiter = _wake;
    _wake = null;
    waiter?.complete();
  }
}

class _SynthOutcome {
  const _SynthOutcome(this.audio) : error = null;
  const _SynthOutcome.failed(this.error) : audio = null;

  final Uint8List? audio;
  final Object? error;
}
