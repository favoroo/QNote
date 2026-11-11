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

  const AiTokenUsage({required this.promptTokens, required this.completionTokens, required this.totalTokens});

  bool get isEmpty => promptTokens == 0 && completionTokens == 0 && totalTokens == 0;

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

    final prompt = read('prompt_tokens') ?? read('input_tokens') ?? read('promptTokenCount');
    final completion = read('completion_tokens') ?? read('output_tokens') ?? read('candidatesTokenCount');
    final reportedTotal = read('total_tokens') ?? read('totalTokenCount');

    final promptTokens = prompt ?? 0;
    final completionTokens = completion ?? 0;
    final derivedTotal = promptTokens + completionTokens;
    // 部分服务商（如 Gemini）的 total 会额外包含思考 token，比输入 + 输出大；
    // 少数中转则把 total 写成 0，此时用输入 + 输出兜底，避免总计被抹平。
    final totalTokens = reportedTotal != null && reportedTotal >= derivedTotal ? reportedTotal : derivedTotal;
    if (totalTokens == 0) return null;

    return AiTokenUsage(promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens);
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

/// Token 消耗明细的时间范围
///
/// 与统计卡的「累计 / 今日 / 近 7 天」同一套自然日口径（本地时区），
/// 只是多给一档近 30 天，方便看月度趋势。
enum AiTokenUsagePeriod {
  /// 今天
  today('今日'),

  /// 近 7 天（含今天）
  week('近 7 天'),

  /// 近 30 天（含今天）
  month('近 30 天'),

  /// 本机全部历史
  all('全部');

  /// 界面展示名
  final String label;

  const AiTokenUsagePeriod(this.label);
}

/// 一个厂商或模型的用量聚合行
///
/// [modelName] 为空串表示这是「厂商合计」行：数据库表里 `model_name` 本就是
/// NOT NULL DEFAULT ''，折叠厂商维度时沿用同一约定，调用方不必再判 null。
class AiTokenUsageBreakdown {
  final String providerId;
  final String modelName;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int requestCount;

  const AiTokenUsageBreakdown({
    required this.providerId,
    this.modelName = '',
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.requestCount,
  });

  /// 是否为厂商维度的合计行
  bool get isProviderTotal => modelName.isEmpty;

  /// 平均每次请求消耗的 token
  int get averagePerRequest => requestCount <= 0 ? 0 : totalTokens ~/ requestCount;

  @override
  String toString() =>
      'AiTokenUsageBreakdown(provider=$providerId, model=$modelName, '
      'total=$totalTokens, requests=$requestCount)';
}

/// Token 消耗明细：一个时间范围内的总量与厂商 / 模型排行
class AiTokenUsageDetail {
  final AiTokenUsagePeriod period;

  /// 该时间范围的总量
  final AiTokenUsageSummary summary;

  /// 厂商排行，按 token 降序
  final List<AiTokenUsageBreakdown> providers;

  /// 模型排行，按 token 降序
  final List<AiTokenUsageBreakdown> models;

  const AiTokenUsageDetail({
    required this.period,
    required this.summary,
    this.providers = const [],
    this.models = const [],
  });

  /// 空明细（读库失败或该范围没有记录时展示空态）
  factory AiTokenUsageDetail.empty(AiTokenUsagePeriod period) {
    return AiTokenUsageDetail(period: period, summary: AiTokenUsageSummary.empty);
  }

  bool get hasData => summary.hasData;

  /// 平均每次请求消耗的 token
  int get averagePerRequest => summary.requestCount <= 0 ? 0 : summary.totalTokens ~/ summary.requestCount;

  @override
  String toString() =>
      'AiTokenUsageDetail(period=$period, total=${summary.totalTokens}, '
      'providers=${providers.length}, models=${models.length})';
}
