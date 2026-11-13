import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/health/health_sync_service.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';

/// 健康数据本地版本号。
///
/// 时间线空位卡与设置页是两条独立的同步入口；任何一次成功同步后自增，
/// 让「某天是否已同步 / 是否有数据」的查询重新落库读取，避免恢复窗口、
/// 切换页面后仍显示旧的「未同步」状态。
final healthSyncVersionProvider = StateProvider<int>((ref) => 0);

/// 小米运动健康是否已绑定（本地存在有效凭证）。
///
/// 时间线只对已绑定用户展示日结空位卡；绑定 / 解绑后由设置页显式失效。
final healthBindingStatusProvider = FutureProvider<bool>((ref) async {
  return ref.watch(healthSyncServiceProvider).isAuthorized();
});

/// 某一天的健康数据同步情况。
typedef HealthDayAvailability = ({bool hasSynced, bool hasData});

/// 读取某天是否同步过、是否真的含有可汇总数据。
///
/// 同步成功但当天无数据时，服务层仍会写入一条全 0 的 `health_daily_metrics`
/// 记录，所以「有记录」只能说明同步过，不能说明有数据；两者要分开判断，
/// 空位卡才能区分「去同步」和「已同步但当天没数据」。
final healthDayAvailabilityProvider = FutureProvider.autoDispose.family<HealthDayAvailability, String>((
  ref,
  date,
) async {
  // 只建立依赖：同步完成后版本号变化，本 Provider 自动重查
  ref.watch(healthSyncVersionProvider);

  final repo = ref.watch(healthMetricRepositoryProvider);
  final metrics = await repo.getDailyMetrics(date);
  if (metrics == null) {
    return (hasSynced: false, hasData: false);
  }
  // 步数/睡眠/消耗都为 0 时，仍可能有纯运动记录（如手动录入的跑步），
  // 与日结卡的 hasData 判定保持一致，需再查一次当天的运动表。
  final sports = await repo.getSportRecordsByDate(date);
  final hasData = metrics.steps > 0 || metrics.sleepDurationMinutes > 0 || metrics.calories > 0 || sports.isNotEmpty;
  return (hasSynced: true, hasData: hasData);
});
