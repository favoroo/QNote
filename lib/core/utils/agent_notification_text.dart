/// 小Q 工作中/完成通知的正文文案格式化（纯函数，便于单测）。
///
/// 通知正文只有一行可见空间：多行 Markdown、表格、超长请求都会把关键信息挤掉，
/// 所以统一压成单行并按字数截断，只保留「任务大致是什么 / 结果大致是什么」。
library;

/// 通知正文字数上限：Android/iOS 折叠态一行约 30~40 字，取 36 留出省略号余量。
const int kAgentNotificationTextMaxLength = 36;

/// 把任意原始文本压成适合通知正文的单行摘要。
///
/// 处理：去 Markdown 强调符号与代码块标记、把换行/连续空白折成单个空格、
/// 去首尾空白，超长时按 [maxLength] 截断并加省略号。空文本返回 [fallback]。
String agentNotificationSummary(
  String? raw, {
  int maxLength = kAgentNotificationTextMaxLength,
  String fallback = '小Q 任务',
}) {
  if (raw == null) return fallback;
  final text = raw
      // 代码围栏与反引号会污染单行展示，直接抹掉
      .replaceAll('```', ' ')
      .replaceAll('`', '')
      // Markdown 标题/列表/引用前缀
      .replaceAll(RegExp(r'^\s{0,3}(#{1,6}|[-*+]|\d+\.|>)\s+', multiLine: true), '')
      // 强调与删除线符号
      .replaceAll(RegExp(r'[*_~]{1,3}'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) return fallback;
  if (text.length <= maxLength) return text;
  // 尽量不截在半个 emoji/代理对上：截断点落在高代理字符之前时回退一位
  var cut = maxLength;
  if (cut > 0 && _isHighSurrogate(text.codeUnitAt(cut - 1))) {
    cut -= 1;
  }
  return '${text.substring(0, cut).trimRight()}…';
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;
