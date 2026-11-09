/// 小浣熊手动签到的结果
///
/// 厂商没有独立的签到接口：签到由开屏接口 `/office/v3/setting_info` 触发，
/// 是否真的到账要靠「签到前后的发放账单差异」判断，所以 [claimed] 与
/// [credit] 是账单对出来的结果，而不是接口的返回码。
class RaccoonCheckInResult {
  /// 本次是否真的领到了积分（false 表示今天之前已经签过、没有新账单）
  final bool claimed;

  /// 本次新到账的积分（已签到过为 0）
  final int credit;

  /// 展示给用户的文案，如「每日签到 +300」「今日已签到」
  final String message;

  /// 本次签到完成的时间
  final DateTime checkedAt;

  const RaccoonCheckInResult({
    required this.claimed,
    required this.credit,
    required this.message,
    required this.checkedAt,
  });
}
