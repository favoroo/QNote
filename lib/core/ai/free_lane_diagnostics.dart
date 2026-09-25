import 'package:qnote_flutter/models/ai_request_stat.dart';

/// 免费网关观测数据的汇总口径（纯函数层）
///
/// 为什么单独成文件而不是写在设置页里：`ai_config_page.dart` 已经 3000+ 行，
/// init 会拉起数据库与全局单例，整页 Widget 测试的成本远大于收益（见 AGENTS.md
/// 「优先测抽出的逻辑与组件」）。把「怎么聚合」抽成不碰 IO 的纯函数后，
/// 页面只负责渲染，聚合口径全部有单测覆盖。
///
/// 汇总要回答的其实是三个问题：哪把 Key 最容易撞墙、撞的是哪一层
/// （秒级 rps 还是分钟额度）、换 Key 之后用户多久能看到第一个字。
class FreeLaneDiagnostics {
  FreeLaneDiagnostics._();

  /// 把事前行按「Key 掩码」与「模型」两个维度聚合
  ///
  /// 排序按限流率降序、再按样本数降序：面板第一眼要看到的是「最成问题的 Key」，
  /// 而 1 条样本 100% 撞墙的噪声必须排在 500 条样本 60% 撞墙的后面。
  static FreeLaneSummary summarize(List<AiRequestStat> rows) {
    return FreeLaneSummary._build(rows);
  }
}

/// 一个维度切片（某把 Key 或某个模型）的统计
class FreeLaneBucket {
  /// 展示名：Key 掩码或模型 id
  final String label;
  final int total;
  final int okCount;
  final int rpsCount;
  final int tpmCount;
  final int authCount;
  final int serverCount;
  final int otherCount;

  /// 参与均值计算的首字样本数（非流式路径不打 TTFT，可能为 0）
  final int ttftSamples;

  /// 首字延迟均值（毫秒）；无样本时为 null
  final int? avgTtftMs;

  /// 整段耗时均值（毫秒）
  final int? avgLatencyMs;

  /// 已上报的 prompt token 合计（网关未回 usage 时为 null，面板据此显示「未上报」）
  final int? promptTokens;

  /// 命中前缀缓存的 prompt token 合计
  final int? cachedTokens;

  FreeLaneBucket({
    required this.label,
    required this.total,
    required this.okCount,
    required this.rpsCount,
    required this.tpmCount,
    required this.authCount,
    required this.serverCount,
    required this.otherCount,
    required this.ttftSamples,
    required this.avgTtftMs,
    required this.avgLatencyMs,
    required this.promptTokens,
    required this.cachedTokens,
  });

  /// 命中服务商限流（rps + 额度）的条数
  int get limitedCount => rpsCount + tpmCount;

  /// 限流率：诊断卡的主指标，也是决定 `poolMaxAttempts` / `tpmCooldown` 是否该调的依据
  double get limitRate => total == 0 ? 0 : limitedCount / total;

  /// 失败率（非成功的任意形态）
  double get failRate => total == 0 ? 0 : (total - okCount) / total;
}

/// 一次汇总的结果：总量 + 按 Key + 按模型
class FreeLaneSummary {
  final int total;
  final int okCount;
  final int rpsCount;
  final int tpmCount;
  final int authCount;
  final int serverCount;
  final int otherCount;
  final int ttftSamples;
  final int? avgTtftMs;
  final int? avgLatencyMs;
  final int? promptTokens;
  final int? cachedTokens;

  /// 覆盖到的模型数（面板副标题用，判断「是不是只测了一个模型」）
  final int modelCount;

  /// 最早/最晚一条事实的时间，用于标注统计窗口
  final DateTime? firstAt;
  final DateTime? lastAt;

  final List<FreeLaneBucket> byKey;
  final List<FreeLaneBucket> byModel;

  const FreeLaneSummary({
    required this.total,
    required this.okCount,
    required this.rpsCount,
    required this.tpmCount,
    required this.authCount,
    required this.serverCount,
    required this.otherCount,
    required this.ttftSamples,
    required this.avgTtftMs,
    required this.avgLatencyMs,
    required this.promptTokens,
    required this.cachedTokens,
    required this.modelCount,
    required this.firstAt,
    required this.lastAt,
    required this.byKey,
    required this.byModel,
  });

  /// 空汇总：页面初始态与「表里还没有数据」共用，面板据此整卡不显示
  const FreeLaneSummary.empty()
    : total = 0,
      okCount = 0,
      rpsCount = 0,
      tpmCount = 0,
      authCount = 0,
      serverCount = 0,
      otherCount = 0,
      ttftSamples = 0,
      avgTtftMs = null,
      avgLatencyMs = null,
      promptTokens = null,
      cachedTokens = null,
      modelCount = 0,
      firstAt = null,
      lastAt = null,
      byKey = const [],
      byModel = const [];

  /// 空数据：面板据此整卡不显示
  bool get isEmpty => total == 0;

  int get limitedCount => rpsCount + tpmCount;

  double get limitRate => total == 0 ? 0 : limitedCount / total;

  double get successRate => total == 0 ? 0 : okCount / total;

  /// token 字段是否有值（大面积为空是预期行为，见 `send_stream_usage` 开关）
  bool get hasTokenData => promptTokens != null;

  static FreeLaneSummary _build(List<AiRequestStat> rows) {
    final byKey = _bucketize(rows, (row) => row.keyMask.isEmpty ? '未标注 Key' : row.keyMask);
    final byModel = _bucketize(rows, (row) => row.modelId.isEmpty ? '未标注模型' : row.modelId);
    final totals = _Accumulator();
    DateTime? firstAt;
    DateTime? lastAt;
    for (final row in rows) {
      totals.add(row);
      if (firstAt == null || row.createdAt.isBefore(firstAt)) firstAt = row.createdAt;
      if (lastAt == null || row.createdAt.isAfter(lastAt)) lastAt = row.createdAt;
    }
    return FreeLaneSummary(
      total: rows.length,
      okCount: totals.ok,
      rpsCount: totals.rps,
      tpmCount: totals.tpm,
      authCount: totals.auth,
      serverCount: totals.server,
      otherCount: totals.other,
      ttftSamples: totals.ttftSamples,
      avgTtftMs: totals.avgTtft,
      avgLatencyMs: totals.avgLatency,
      promptTokens: totals.promptTokens,
      cachedTokens: totals.cachedTokens,
      modelCount: byModel.length,
      firstAt: firstAt,
      lastAt: lastAt,
      byKey: byKey,
      byModel: byModel,
    );
  }

  /// 排序按「限流条数 → 限流率 → 样本数」降序：面板第一眼要指出**谁在真正浪费额度**。
  ///
  /// 不能只按比率排：1 条样本 100% 撞墙的噪声会永远压过 5 条样本 60% 撞墙的真问题，
  /// 而后者才是该调 `tpmCooldown` / `poolMaxAttempts` 的信号。先数条数再数比率，
  /// 等价于给样本量加了权，也不需要引入 Wilson 区间这类面板用不起的复杂度。
  static List<FreeLaneBucket> _bucketize(
    List<AiRequestStat> rows,
    String Function(AiRequestStat row) labelOf,
  ) {
    final groups = <String, _Accumulator>{};
    for (final row in rows) {
      (groups[labelOf(row)] ??= _Accumulator()).add(row);
    }
    final buckets = groups.entries.map((e) => e.value.toBucket(e.key)).toList()
      ..sort((a, b) {
        final byLimited = b.limitedCount.compareTo(a.limitedCount);
        if (byLimited != 0) return byLimited;
        final byRate = b.limitRate.compareTo(a.limitRate);
        if (byRate != 0) return byRate;
        return b.total.compareTo(a.total);
      });
    return buckets;
  }
}

/// 累加器：把「按维度计数 + 求均值」的样板收在一处，避免六个字段各写一遍
class _Accumulator {
  int ok = 0;
  int rps = 0;
  int tpm = 0;
  int auth = 0;
  int server = 0;
  int other = 0;
  int count = 0;
  int ttftSamples = 0;
  int ttftSum = 0;
  int latencySamples = 0;
  int latencySum = 0;
  int? promptTokens;
  int? cachedTokens;

  void add(AiRequestStat row) {
    count++;
    switch (row.outcome) {
      case AiRequestOutcomes.ok:
        ok++;
        break;
      case AiRequestOutcomes.rps:
        rps++;
        break;
      case AiRequestOutcomes.tpm:
        tpm++;
        break;
      case AiRequestOutcomes.auth:
        auth++;
        break;
      case AiRequestOutcomes.server:
        server++;
        break;
      default:
        other++;
    }
    final ttft = row.ttftMs;
    if (ttft != null && ttft > 0) {
      ttftSamples++;
      ttftSum += ttft;
    }
    if (row.latencyMs > 0) {
      latencySamples++;
      latencySum += row.latencyMs;
    }
    if (row.promptTokens != null) {
      promptTokens = (promptTokens ?? 0) + row.promptTokens!;
    }
    if (row.cachedTokens != null) {
      cachedTokens = (cachedTokens ?? 0) + row.cachedTokens!;
    }
  }

  int? get avgTtft => ttftSamples == 0 ? null : (ttftSum / ttftSamples).round();

  int? get avgLatency =>
      latencySamples == 0 ? null : (latencySum / latencySamples).round();

  FreeLaneBucket toBucket(String label) {
    return FreeLaneBucket(
      label: label,
      total: count,
      okCount: ok,
      rpsCount: rps,
      tpmCount: tpm,
      authCount: auth,
      serverCount: server,
      otherCount: other,
      ttftSamples: ttftSamples,
      avgTtftMs: avgTtft,
      avgLatencyMs: avgLatency,
      promptTokens: promptTokens,
      cachedTokens: cachedTokens,
    );
  }
}

/// 面板文案格式化（也放纯函数层，方便断言「38%」而不是 0.3799999）
class FreeLaneFormats {
  FreeLaneFormats._();

  static const String dash = '—';

  /// 0.379 → `38%`
  static String percent(double ratio) => '${(ratio * 100).round()}%';

  /// 毫秒 → 人眼可读：小于 1 秒用 ms，否则用一位小数的秒
  static String duration(int? ms) {
    if (ms == null || ms <= 0) return dash;
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  /// token 数：未上报时明确写「未上报」，避免被误读成「消耗为 0」
  static String tokens(int? value) => value == null ? '未上报' : '$value';
}
