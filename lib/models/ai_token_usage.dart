/// 一次 AI 响应上报的 token 用量
///
/// 不同厂商字段名不一致：OpenAI 兼容端点用 `usage.prompt_tokens` /
/// `completion_tokens`，Gemini 用 `usageMetadata.promptTokenCount` /
/// `candidatesTokenCount`，部分中转还会写成 `input_tokens` / `output_tokens`。
/// 这里统一收敛成输入 / 输出 / 总计三元组，展示层不必再判厂商。
class AiTokenUsage {
  /// 输入（prompt）token
  final int promptTokens;

  /// 输出（completion）token
  final int completionTokens;

  /// 总计 token；服务端未上报时由输入 + 输出兜底
  final int totalTokens;

  const AiTokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  bool get isEmpty =>
      promptTokens == 0 && completionTokens == 0 && totalTokens == 0;

  /// 从响应体（含流式最后一帧）解析 usage；服务端未上报时返回 null
  ///
  /// 流式 usage 末帧的 `choices` 是空数组，因此这里只读 `usage` /
  /// `usageMetadata`，不依赖任何正文结构，调用方可以在解析 delta 之前调用。
  static AiTokenUsage? fromResponse(Object? data) {
    if (data is! Map) return null;
    final rawUsage = data['usage'] ?? data['usageMetadata'];
    if (rawUsage is! Map) return null;

    int? read(String key) {
      final raw = rawUsage[key];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    }

    final prompt = read('prompt_tokens') ??
        read('input_tokens') ??
        read('promptTokenCount');
    final completion = read('completion_tokens') ??
        read('output_tokens') ??
        read('candidatesTokenCount');
    final reportedTotal = read('total_tokens') ?? read('totalTokenCount');

    final promptTokens = prompt ?? 0;
    final completionTokens = completion ?? 0;
    final derivedTotal = promptTokens + completionTokens;
    // 部分服务商（如 Gemini）的 total 会额外包含思考 token，比输入 + 输出大；
    // 少数中转则把 total 写成 0，此时用输入 + 输出兜底，避免总计被抹平。
    final totalTokens = reportedTotal != null && reportedTotal >= derivedTotal
        ? reportedTotal
        : derivedTotal;
    if (totalTokens == 0) return null;

    return AiTokenUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiTokenUsage &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens &&
      other.totalTokens == totalTokens;

  @override
  int get hashCode => Object.hash(promptTokens, completionTokens, totalTokens);

  @override
  String toString() =>
      'AiTokenUsage(prompt=$promptTokens, completion=$completionTokens, '
      'total=$totalTokens)';
}

/// AI 配置页展示用的累计口径（本机、本地表聚合）
class AiTokenUsageSummary {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int requestCount;

  /// 今日消耗的总 token（自然日，本地时区）
  final int todayTokens;

  /// 近 7 天（含今天）消耗的总 token
  final int weekTokens;

  const AiTokenUsageSummary({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.requestCount = 0,
    this.todayTokens = 0,
    this.weekTokens = 0,
  });

  static const AiTokenUsageSummary empty = AiTokenUsageSummary();

  bool get hasData => requestCount > 0 || totalTokens > 0;

  @override
  String toString() =>
      'AiTokenUsageSummary(total=$totalTokens, prompt=$promptTokens, '
      'completion=$completionTokens, requests=$requestCount)';
}
