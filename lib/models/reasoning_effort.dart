/// 思考强度档位：跨厂商统一的语义，具体请求参数由
/// `ModelReasoningCapability` 按模型族映射到各家的私有字段。
///
/// 持久化到 `ai_providers.models[].reasoning_effort`；为空表示「自动」，
/// 即不额外干预、由模型服务决定。
enum ReasoningEffort {
  none('none', '关闭'),
  low('low', '低'),
  medium('medium', '中'),
  high('high', '高');

  const ReasoningEffort(this.wireName, this.label);

  /// 写入 JSON 的稳定标识，避免直接依赖枚举下标
  final String wireName;

  /// 界面展示文案
  final String label;

  /// 解析持久化值；空值或未知值返回 null（等同「自动」）
  static ReasoningEffort? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    final value = raw.trim().toLowerCase();
    for (final effort in values) {
      if (effort.wireName == value) {
        return effort;
      }
    }
    return null;
  }
}
