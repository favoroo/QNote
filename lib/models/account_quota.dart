/// 订阅账号的额度快照（一次查询的结果，只存在内存里，不落库）
///
/// 各厂商的额度接口形状不同，这里只保留界面真正要展示的公共字段：
/// - [balance]：当前可用积分/余额；
/// - [plan] / [planExpiresAt]：套餐与到期时间（没有套餐概念的厂商留空）；
/// - [detail]：厂商特有的补充说明（如钱包拆分、今日签到状态）。
class AccountQuota {
  /// 当前可用积分/余额
  final int balance;

  /// `Free` / `Pro` / 套餐名；查询失败或厂商没有套餐概念时为空
  final String plan;

  /// 付费套餐到期时间（免费版或没有套餐概念时为空）
  final DateTime? planExpiresAt;

  /// 追加在积分后面的补充说明，例如「赠送积分 500 · 今日已签 +5」
  final String detail;

  /// 本次查询完成的时间（界面上用来标注「几点更新」）
  final DateTime fetchedAt;

  const AccountQuota({
    required this.balance,
    this.plan = '',
    this.planExpiresAt,
    this.detail = '',
    required this.fetchedAt,
  });

  bool get hasPlan => plan.trim().isNotEmpty;

  bool get hasDetail => detail.trim().isNotEmpty;
}