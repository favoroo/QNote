import 'package:qnote_flutter/core/tts/speech_tuning.dart';
import 'package:qnote_flutter/core/tts/tts_service.dart';
import 'package:qnote_flutter/core/utils/speech_chunker.dart';

/// 把任意文本（整块一次到位，或流式增量喂入）变成可直接送合成的朗读段。
///
/// 串起三件事：[SpeechChunker] 按句读切分、[TtsService.cleanSpeechText] 去
/// markdown 噪音、[SpeechTuning.maxSessionChars] 总量护栏。手动点「朗读」与
/// 小Q自动朗读共用本类，两条路径的截断与清洗行为才不会分叉。
class SpeechSegmentBuilder {
  SpeechSegmentBuilder({
    this.maxTotalChars = SpeechTuning.maxSessionChars,
    SpeechChunker? chunker,
  }) : _chunker = chunker ?? SpeechChunker();

  /// 超长时补在最后的提示语（沿用旧整段朗读的措辞，用户听得懂"后面没念"）
  static const String clippedSuffix = '……后文略。';

  final SpeechChunker _chunker;
  final int maxTotalChars;

  /// 已产出的可朗读字数（清洗后累计），用于总量护栏
  int _spoken = 0;

  /// 是否已触顶（触顶后只保留最后那句「后文略」，不再产出正文）
  bool _exhausted = false;

  /// 已触顶：后续增量直接丢弃
  bool get isExhausted => _exhausted;

  /// 已产出的朗读字数（供上层日志与调试）
  int get spokenChars => _spoken;

  /// 喂入流式增量，返回本次可朗读的片段。
  List<String> feed(String delta) => _emit(_chunker.feed(delta));

  /// 收尾：吐出未满门槛的尾巴，必要时补一句「后文略」。
  List<String> finish() {
    final out = _emit(_chunker.flush());
    if (_exhausted && out.isEmpty) out.add(clippedSuffix);
    return out;
  }

  /// 作废本轮（Agent 新一轮会清空正文缓冲，朗读跟着重来）
  void reset() {
    _chunker.discard();
    _spoken = 0;
    _exhausted = false;
  }

  /// 是否还没有任何可朗读内容（上层据此判断"还没开口，不必打断正在播的音频"）
  bool get isEmpty => _chunker.isEmpty;

  List<String> _emit(List<String> rawSegments) {
    final out = <String>[];
    for (final raw in rawSegments) {
      if (_exhausted) break;
      final cleaned = TtsService.cleanSpeechText(raw, maxChars: null);
      if (cleaned.isEmpty) continue;
      if (_spoken + cleaned.length > maxTotalChars) {
        // 越线的那一段整体放弃，比从句子中间截断更好听
        _exhausted = true;
        break;
      }
      _spoken += cleaned.length;
      out.add(cleaned);
    }
    return out;
  }
}
