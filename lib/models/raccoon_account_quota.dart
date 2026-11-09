/// 小浣熊账号的额度快照（一次查询的结果，只存在内存里，不落库）
///
/// 字段口径与 magpie 插件一致：
/// - 余额优先读 `/points/v1/balance`，被厂商拒绝（403）时回落到
///   `/office/v3/setting_info`，两处都是 `available_points`；
/// - 套餐来自 `/auth/v1/entitlement_info`，读不到时留空而不是当成 Free；
/// - `pro_enable` 为真时套餐名取 `active_plan.type`，缺失时显示 Pro。
class RaccoonAccountQuota {
  /// 当前可用积分
  final int availablePoints;

  /// `Free` / `Pro` / 套餐名；查询失败或读不到时为空
  final String plan;

  /// 付费套餐到期时间（免费版为空）
  final DateTime? planExpiresAt;

  /// 本次查询完成的时间（界面上用来标注「几点更新」）
  final DateTime fetchedAt;

  const RaccoonAccountQuota({
    required this.availablePoints,
    this.plan = '',
    this.planExpiresAt,
    required this.fetchedAt,
  });

  bool get hasPlan => plan.trim().isNotEmpty;
}