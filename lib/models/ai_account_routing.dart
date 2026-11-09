/// 订阅账号的选号策略与亲和时长
///
/// 语义对齐 magpie 的 `Routing` / `Affinity`（`internal/provider/group.go`）：
/// - 选号策略决定「这次用哪个账号」；
/// - 亲和时长决定「一段对话在同一账号上待多久」——待得越久，厂商侧的
///   prompt cache 越能命中，重复计费的上下文越少。
///
/// 落库是字符串 id（`ai_providers.account_routing` / `account_affinity`），
/// 与枚举名解耦，以后增删策略不会让旧数据解析失败。
library;

/// 多账号的选号策略
enum AccountRouting {
  /// 每次换下一个账号：把请求摊到多个账号上，规避单账号限流
  rotate('rotate', '轮流', '每次请求换下一个账号，分散限流'),

  /// 始终优先第一个可用账号，它不可用才换下一个
  failover('failover', '顺序', '优先用排在前面的账号，不可用时自动换下一个'),

  /// 按近期成功率与使用次数挑当前最稳的账号
  smart('smart', '智能', '自动选当前最稳、用得最少的账号');

  const AccountRouting(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static AccountRouting fromId(String? raw) {
    for (final value in values) {
      if (value.id == raw) return value;
    }
    // 未知/缺失一律按「轮流」处理：旧数据与手改配置都能安全打开
    return rotate;
  }
}

/// 一段对话在同一账号上待多久
///
/// 默认 [session]：同一个对话固定用同一个账号，换对话才轮到下一个。
/// 这比「每个请求都换」更省上下文费用，也比「永远不换」更能摊开限流。
enum AccountAffinity {
  /// 整个对话固定同一账号，直到该账号失效/限流才换
  session('session', '会话亲和', '同一对话固定用同一账号，换对话才轮换'),

  /// 每条用户消息换一次账号，消息内部的工具循环保持同一账号
  turn('turn', '每轮轮换', '每条消息换一次账号，同一条消息内保持一致'),

  /// 不亲和：每个请求都按选号策略走
  off('off', '不亲和', '每个请求都按策略重新选账号'),

  /// 严格亲和：对话固定账号，即使它限流/失败也不换（错误直接抛给用户）
  strict('strict', '严格亲和', '固定账号，即使失败也不切换（会直接报错）');

  const AccountAffinity(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static AccountAffinity fromId(String? raw) {
    for (final value in values) {
      if (value.id == raw) return value;
    }
    // 缺失时按「会话亲和」处理：单账号场景行为完全一致
    return session;
  }
}
