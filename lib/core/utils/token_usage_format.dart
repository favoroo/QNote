/// Token 数量的紧凑展示：1.2K / 12.3K / 1.23M
///
/// 配置页卡片空间有限，完整数字会撑破一行；精确值由调用方放进 Tooltip。
String formatTokenCount(int value) {
  if (value < 0) return '0';
  if (value < 1000) return '$value';
  if (value < 1000000) {
    final k = value / 1000;
    return '${_trimTrailingZero(k >= 100 ? k.round().toString() : k.toStringAsFixed(1))}K';
  }
  final m = value / 1000000;
  return '${_trimTrailingZero(m >= 100 ? m.round().toString() : m.toStringAsFixed(2))}M';
}

/// Token 数量的精确展示：123,456
String formatTokenCountExact(int value) {
  if (value <= 0) return '0';
  return value.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (match) => '${match[1]},');
}

String _trimTrailingZero(String text) {
  if (!text.contains('.')) return text;
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}
