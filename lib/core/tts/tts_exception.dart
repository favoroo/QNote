/// TTS 合成/朗读异常（统一错误类型，供降级链与 UI 提示判断）
class TtsException implements Exception {
  /// 机器可读的错误码：`unsupported_platform` / `synthesis_failed` /
  /// `empty_text` / `speech_failed` 等
  final String code;

  /// 面向用户的中文描述
  final String message;

  const TtsException(this.code, this.message);

  @override
  String toString() => 'TtsException($code): $message';
}
