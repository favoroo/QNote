/// 「给小Q」光标上下文摘录工具。
///
/// 编辑器未框选文字、仅有光标时点「给小Q」，用本函数把光标附近文本
/// 连同【光标】标记摘录下来作为引用（QTextQuote.quotedText），
/// 小Q 端据此定位插入点（见 floating_q_provider 对【光标】标记的续写引导）。
library;

/// 构建光标上下文摘录：取 [offset] 前后各 [contextChars] 字并在中间插入【光标】标记。
///
/// - 文本为空白（无任何实质内容）时返回空字符串，空态文案由调用方决定；
/// - 摘录起点/终点不在文本边界时以「…」提示被截断；
/// - [offset] 超出文本范围时自动收敛到合法区间，不抛异常。
String buildCursorContextSnippet(String text, int offset, {int contextChars = 60}) {
  final safeOffset = offset.clamp(0, text.length);
  if (text.trim().isEmpty) return '';

  final start = (safeOffset - contextChars).clamp(0, text.length);
  final end = (safeOffset + contextChars).clamp(0, text.length);
  final pre = text.substring(start, safeOffset);
  final post = text.substring(safeOffset, end);
  final prePrefix = start > 0 ? '…' : '';
  final postSuffix = end < text.length ? '…' : '';
  return '$prePrefix$pre【光标】$post$postSuffix';
}
