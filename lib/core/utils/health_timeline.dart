/// 时间线「运动健康日结」空位卡的纯逻辑。
///
/// 真实日结卡是同步成功后写入的一条日记记录；没有同步、同步失败或当天无数据时
/// 时间线上原本什么都没有。这里只判断「该不该补一张空位卡」以及空位卡该显示哪种
/// 同步状态，不依赖 Widget、数据库与网络。
library;

import 'diary_timeline_layout.dart';

/// 空位卡的同步状态文案分支。
enum HealthPlaceholderMode {
  /// 这一天从未同步过。
  unsynced,

  /// 已同步过，但当天没有任何可汇总的健康数据。
  syncedEmpty,

  /// 已同步到数据，但日结卡缺失（旧版本数据或卡片被删）。
  syncedWithoutCard,
}

/// 时间线是否应为 [date] 显示运动健康空位卡。
///
/// - 只覆盖今天与过去：未来日期没有可同步的数据；
/// - 当天已有 `daily_summary` 卡片时不再重复显示；
/// - 未绑定小米运动健康时整体隐藏，避免给不使用该功能的用户制造噪音。
bool shouldShowHealthDailyPlaceholder({
  required DateTime date,
  required DateTime today,
  required bool hasDailySummary,
  required bool healthBound,
}) {
  if (!healthBound || hasDailySummary) {
    return false;
  }
  return !diaryDateOnly(date).isAfter(diaryDateOnly(today));
}

/// 根据本地同步记录推导空位卡状态。
///
/// [hasSynced] 表示当天在 `health_daily_metrics` 有落库记录（同步成功但无数据也会
/// 写一条全 0 记录）；[hasData] 表示步数/睡眠/消耗/运动至少一项有值，与
/// `HealthSyncService` 生成日结卡的判定口径一致。
HealthPlaceholderMode resolveHealthPlaceholderMode({required bool hasSynced, required bool hasData}) {
  if (!hasSynced) {
    return HealthPlaceholderMode.unsynced;
  }
  return hasData ? HealthPlaceholderMode.syncedWithoutCard : HealthPlaceholderMode.syncedEmpty;
}
