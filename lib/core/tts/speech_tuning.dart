import 'package:qnote_flutter/core/utils/speech_chunker.dart';

/// 流式分段朗读的调参收口：段长、起播门槛、总量护栏与预取深度。
///
/// 这些数值互相牵连（门槛太小会合成风暴、太大会拖慢首声），集中一处便于
/// 真机听感调优时一次看全，避免散落在切分器、播放器与两条对话链路里各写一份。
class SpeechTuning {
  SpeechTuning._();

  /// 首段起播门槛（清洗后字数）：约 40 字 ≈ 十来秒朗读，既能让声音尽快起来，
  /// 又能挡掉工具轮「我先看看这个文件」这类短开场白被念出来
  static const int minSegmentChars = SpeechChunker.defaultMinChars;

  /// 目标段长：超过它即使没有句末标点也倾向于在子句处收尾
  static const int maxSegmentChars = SpeechChunker.defaultMaxChars;

  /// 无句末标点时的硬切阈值：宁可断句也不能让下一段无限等下去
  static const int hardLimitChars = SpeechChunker.defaultHardLimit;

  /// 单场朗读总量护栏（清洗后累计字数）。
  ///
  /// 取代旧 `TtsService.maxSpeechChars = 600` 的截断职责：分段后单段很短，
  /// 逐段截断会让每段都挂上「后文略」，改由会话侧按累计长度收口。
  static const int maxSessionChars = 1500;

  /// 预取段数：播放第 N 段时后台先把 N+1、N+2 段合成好，
  /// 用并发预取掩盖 Edge 每段一次 WebSocket 握手的固定开销
  static const int prefetchDepth = 2;
}
