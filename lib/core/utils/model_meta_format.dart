/// 模型目录元数据的展示文案（倍率、上下文窗口）
///
/// 抽成纯函数：模型列表、选择器与后续可能的用量页都要用同一套口径，
/// 免得一处写「1.0×」另一处写「1×」。
library;

/// 倍率 → `0.25×` / `1×`；没有倍率信息时返回 null
String? formatRate(num? rate) {
  if (rate == null) return null;
  final text = rate == rate.roundToDouble() ? rate.toInt().toString() : rate.toString();
  return '$text×';
}

/// 上下文窗口 → `1M` / `256K`；没有信息时返回 null
String? formatContextWindow(int? tokens) {
  if (tokens == null || tokens <= 0) return null;
  if (tokens >= 1000000) {
    // 先按 0.1M 取整：1_048_576（1M 的二进制近似）要显示成 1M 而不是 1.0M
    final millions = (tokens / 1000000 * 10).round() / 10;
    final text = millions == millions.roundToDouble() ? millions.toInt().toString() : millions.toStringAsFixed(1);
    return '${text}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}K';
  return '$tokens';
}
