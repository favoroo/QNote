/// 订阅账号手动签到的结果
///
/// 各厂商的签到接口形态不同（小浣熊靠开屏接口触发、AutoClaw 有独立任务接口），
/// 上层只关心两件事：这次到底有没有领到积分，以及给用户看什么文案。
class AccountCheckInResult {
  /// 本次是否真的领到了积分（false 表示今天之前已经签过、没有新到账）
  final bool claimed;

  /// 本次新到账的积分（已签到过为 0）
  final int credit;

  /// 展示给用户的文案，如「每日签到 +300」「今日已签到」
  final String message;

  /// 本次签到完成的时间
  final DateTime checkedAt;

  const AccountCheckInResult({
    required this.claimed,
    required this.credit,
    required this.message,
    required this.checkedAt,
  });
}
