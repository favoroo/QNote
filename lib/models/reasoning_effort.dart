/// 思考强度档位：跨厂商统一的语义，具体请求参数由
/// `ModelReasoningCapability` 按模型族映射到各家的私有字段。
///
/// 持久化到 `ai_providers.models[].reasoning_effort`；为空表示「自动」，
/// 即不额外干预、由模型服务决定。
///
/// 枚举顺序即由弱到强，配置页与档位 chips 都按这个顺序展示。`minimal`、
/// `xhigh`、`max` 不是每家都认，默认只开放能力表确认过的档位，用户可在
/// 模型配置里按需勾选；不认的端点由发信层的 400 降级兜住。
enum ReasoningEffort {
  none('none', '关闭', '不思考，响应最快'),
  minimal('minimal', '最少', '尽量少思考，比「低」更省'),
  low('low', '低', '少量思考，更快'),
  medium('medium', '中', '较充分思考，适合多数任务'),
  high('high', '高', '思考最充分，复杂任务更稳但更慢'),
  xhigh('xhigh', '极高', '更深的推理，耗时与用量更高'),
  max('max', '最高', '最深推理，适合极难任务');

  const ReasoningEffort(this.wireName, this.label, this.description);

  /// 写入 JSON 的稳定标识，避免直接依赖枚举下标
  final String wireName;

  /// 界面展示文案
  final String label;

  /// 档位的一句说明，选择面板与配置页共用
  final String description;

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

  /// 解析一组持久化值：去重、按由弱到强排序，空列表返回 null（等同「自动」）
  static List<ReasoningEffort>? tryParseList(Object? raw) {
    if (raw is! List) return null;
    final parsed = <ReasoningEffort>{};
    for (final item in raw) {
      final effort = tryParse(item?.toString());
      if (effort != null) parsed.add(effort);
    }
    if (parsed.isEmpty) return null;
    return [
      for (final effort in values)
        if (parsed.contains(effort)) effort,
    ];
  }
}
