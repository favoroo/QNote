/// 免费网关的一次发信结果（对应表 `ai_request_stats`）
///
/// 存在的理由是**内置池的调参只能靠数据**：9 把共享 Key 的实际撞墙分布、
/// 哪个形态占多数（rps 突发还是分钟额度）、换 Key 之后首包要等多久，
/// 这些在 35 条环形日志里永远看不出来（`LoggerService` 不落盘历史）。
/// 本表按 CPA `usage.db` 的思路逐请求记一行事实，设置页的诊断卡再聚合展示。
///
/// 刻意**不记录任何明文凭证**：[keyMask] 存的是 `FreeModelKeyManager.maskKey` 的
/// 前 4 + 后 4 掩码，足以区分 9 把 Key，又不需要为本项目新增一个「数据库里存着
/// API Key」的泄露面（数据库会随 WebDAV 备份导出）。
class AiRequestStat {
  /// 自增主键（观测行不跨设备合并，用不到业务 id）
  final int? id;

  /// 发信场景：`chat_stream` / `chat` / `extract` / `daily_score` / `image` / `test`
  final String scene;

  /// 实际下发给网关的模型 id
  final String modelId;

  /// 本次真正使用的 Key 掩码（非内置池请求为空串）
  final String keyMask;

  /// 结果归类，取值见 [AiRequestOutcomes]
  final String outcome;

  /// HTTP 状态码；带内错误（HTTP 200 但 SSE 帧里塞 error）与连接失败为 null
  final int? httpStatus;

  /// 整段耗时（毫秒）：流式为「发信到流结束」，失败为「发信到判定失败」
  final int latencyMs;

  /// 首个可见增量（正文或思考）的毫秒数；非流式路径为 null
  final int? ttftMs;

  /// usage 里的 prompt tokens；网关未上报时为 null（见 `sendStreamUsage` 开关）
  final int? promptTokens;
  final int? completionTokens;

  /// 命中前缀缓存的 prompt tokens：逐请求换 Key 之后它直接回答「轮换是否打掉了缓存」
  final int? cachedTokens;

  /// `YYYYMMDDHH` 分桶键，按小时聚合用（时间戳列是 TEXT，range 扫描不如等值命中划算）
  final String hourBucket;

  final DateTime createdAt;

  AiRequestStat({
    this.id,
    required this.scene,
    required this.modelId,
    required this.keyMask,
    required this.outcome,
    required this.latencyMs,
    required this.createdAt,
    this.httpStatus,
    this.ttftMs,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
    String? hourBucket,
  }) : hourBucket = hourBucket ?? AiRequestStat.hourBucketOf(createdAt);

  /// 是否成功产出（诊断卡的「成功率」口径）
  bool get isSuccess => outcome == AiRequestOutcomes.ok;

  /// 是否属于服务商限流（rps 与额度两类合起来的命中率）
  bool get isLimited =>
      outcome == AiRequestOutcomes.rps || outcome == AiRequestOutcomes.tpm;

  /// 按小时分桶：`YYYYMMDDHH`（本地时区，纯数字便于肉眼排序）
  ///
  /// 手工拼接而不用 `formatDate`：一是避免为一张观测表引入 intl 依赖，
  /// 二是分桶键必须与 [parseHourBucket] 严格互逆，格式定死更安全。
  static String hourBucketOf(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}${two(local.month)}${two(local.day)}${two(local.hour)}';
  }

  /// 分桶键 → 该小时起点；格式非法返回 null
  static DateTime? parseHourBucket(String bucket) {
    if (bucket.length != 10) return null;
    final y = int.tryParse(bucket.substring(0, 4));
    final m = int.tryParse(bucket.substring(4, 6));
    final d = int.tryParse(bucket.substring(6, 8));
    final h = int.tryParse(bucket.substring(8, 10));
    if (y == null || m == null || d == null || h == null) return null;
    return DateTime(y, m, d, h);
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'scene': scene,
      'model_id': modelId,
      'key_mask': keyMask,
      'outcome': outcome,
      'http_status': httpStatus,
      'latency_ms': latencyMs,
      'ttft_ms': ttftMs,
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'cached_tokens': cachedTokens,
      'hour_bucket': hourBucket,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory AiRequestStat.fromMap(Map<String, dynamic> map) {
    return AiRequestStat(
      id: map['id'] as int?,
      scene: map['scene'] as String? ?? '',
      modelId: map['model_id'] as String? ?? '',
      keyMask: map['key_mask'] as String? ?? '',
      outcome: map['outcome'] as String? ?? AiRequestOutcomes.other,
      httpStatus: map['http_status'] as int?,
      latencyMs: (map['latency_ms'] as int?) ?? 0,
      ttftMs: map['ttft_ms'] as int?,
      promptTokens: map['prompt_tokens'] as int?,
      completionTokens: map['completion_tokens'] as int?,
      cachedTokens: map['cached_tokens'] as int?,
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
      hourBucket: map['hour_bucket'] as String?,
    );
  }

  AiRequestStat copyWith({
    int? id,
    String? scene,
    String? modelId,
    String? keyMask,
    String? outcome,
    int? httpStatus,
    int? latencyMs,
    int? ttftMs,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    String? hourBucket,
    DateTime? createdAt,
  }) {
    return AiRequestStat(
      id: id ?? this.id,
      scene: scene ?? this.scene,
      modelId: modelId ?? this.modelId,
      keyMask: keyMask ?? this.keyMask,
      outcome: outcome ?? this.outcome,
      httpStatus: httpStatus ?? this.httpStatus,
      latencyMs: latencyMs ?? this.latencyMs,
      ttftMs: ttftMs ?? this.ttftMs,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      hourBucket: hourBucket ?? this.hourBucket,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// [AiRequestStat.outcome] 的取值集合
///
/// 与 `QuotaSignal` 一一对应再加 `ok` / `other`：库里存字符串而不是枚举序号，
/// 是为了让直接查库（adb / DB Browser）就能读懂，观测表的首要读者是人不是代码。
class AiRequestOutcomes {
  AiRequestOutcomes._();

  static const String ok = 'ok';

  /// 秒级突发（`rps exhausted`）
  static const String rps = 'rps';

  /// 分钟额度（`EndpointTPMExceeded` / `rpm exhausted` / 429 无正文）
  static const String tpm = 'tpm';

  /// 401/403：Key 失效或无该模型权限
  static const String auth = 'auth';

  /// 5xx：网关侧故障，与 Key 无关
  static const String server = 'server';

  /// 其它失败（连接层、业务 4xx、解析失败）
  static const String other = 'other';
}
