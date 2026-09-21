import 'package:flutter/material.dart';

import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';
import 'package:qnote_flutter/widgets/health/heart_rate_detail.dart';
import 'package:qnote_flutter/widgets/health/sleep_detail.dart';
import 'package:qnote_flutter/widgets/health/sport_detail.dart';
import 'package:qnote_flutter/widgets/health/vitals_detail.dart';

/// 健康指标二级详情页的类别
enum HealthMetricKind { sleep, heartRate, vitals, sport }

/// `/health-detail` 的路由参数
///
/// 传的是**已加载好的数据**而不是日期：主看板已经把 `HealthDailyMetrics` 读进内存，
/// 详情页再走一遍 Provider/DB 只会多出加载态与竞态，也让页面难以用 fixture 直接测。
class HealthDetailArgs {
  const HealthDetailArgs({
    required this.kind,
    required this.title,
    this.dateLabel,
    this.metrics,
    this.sport,
  });

  final HealthMetricKind kind;
  final String title;

  /// 形如「9月20日」，显示在标题下方
  final String? dateLabel;
  final HealthDailyMetrics? metrics;
  final HealthSportRecord? sport;
}

/// 健康指标二级详情页容器：统一 AppBar 与空态，内容按类别分派
class HealthMetricDetailPage extends StatelessWidget {
  const HealthMetricDetailPage({super.key, required this.args});

  final HealthDetailArgs args;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(args.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (args.dateLabel != null)
              Text(
                args.dateLabel!,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        centerTitle: false,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (args.kind) {
      case HealthMetricKind.heartRate:
        final m = args.metrics;
        if (m == null) return const _HealthDetailEmpty();
        return HeartRateDetail(metrics: m);
      case HealthMetricKind.vitals:
        final m = args.metrics;
        if (m == null) return const _HealthDetailEmpty();
        return VitalsDetail(metrics: m);
      case HealthMetricKind.sleep:
        final m = args.metrics;
        if (m == null) return const _HealthDetailEmpty();
        return SleepDetail(metrics: m);
      case HealthMetricKind.sport:
        final r = args.sport;
        if (r == null) return const _HealthDetailEmpty();
        return SportDetail(record: r);
    }
  }
}

class _HealthDetailEmpty extends StatelessWidget {
  const _HealthDetailEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.monitor_heart_outlined, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              '这一天没有可展示的健康数据',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
