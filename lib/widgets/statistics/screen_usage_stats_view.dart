import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/health/screen_usage_snapshot_service.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/providers/screen_usage_provider.dart';
import 'package:qnote_flutter/providers/selected_date_provider.dart';
import 'package:qnote_flutter/widgets/statistics/date_navigation_header.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';

/// 屏幕使用时长统计视图
///
/// 同时挂在「数据统计 → 屏幕时长」tab 与设置页的独立页上，因此区间选择条由本视图
/// 自己渲染，不依赖宿主页面下发；日期沿用全局 selectedDateProvider 与评分 tab 保持一致。
class ScreenUsageStatsView extends ConsumerStatefulWidget {
  const ScreenUsageStatsView({super.key});

  @override
  ConsumerState<ScreenUsageStatsView> createState() => ScreenUsageStatsViewState();
}

class ScreenUsageStatsViewState extends ConsumerState<ScreenUsageStatsView> with WidgetsBindingObserver {
  static const Color _accent = Color(0xFF388AF6);

  bool _isLoading = true;
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAndLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统「有权查看使用情况的应用」设置页返回，或跨天后回到前台时，
    // 都需要重新鉴权并补采快照
    if (state == AppLifecycleState.resumed) {
      _checkAndLoad();
    }
  }

  /// 外部调用手动刷新数据
  Future<void> refresh() => _checkAndLoad(force: true);

  Future<void> _checkAndLoad({bool force = false}) async {
    final service = ref.read(screenUsageServiceProvider);
    if (!service.isSupported) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    final authed = await service.hasPermission();
    if (!mounted) {
      return;
    }
    if (!authed) {
      setState(() {
        _hasPermission = false;
        _isLoading = false;
      });
      return;
    }

    // 先把逐日数值落库，再让各 provider 重读，保证看到的不是上一轮的旧快照
    final wrote = await ref.read(screenUsageSnapshotServiceProvider).ensureSnapshot(force: force);
    if (!mounted) {
      return;
    }
    if (wrote) {
      _invalidateData();
    }

    setState(() {
      _hasPermission = true;
      _isLoading = false;
    });
  }

  void _invalidateData() {
    ref.invalidate(screenUsageDayProvider);
    ref.invalidate(screenUsageRangeProvider);
    ref.invalidate(screenUsageTrendProvider);
    ref.invalidate(screenUsageEarliestDateProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final service = ref.read(screenUsageServiceProvider);

    if (!service.isSupported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_android_rounded, size: 64, color: colorScheme.outline),
              const SizedBox(height: 16),
              Text(
                '屏幕使用时间统计仅支持 Android 设备',
                style: theme.textTheme.titleMedium?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasPermission) {
      return _buildPermissionGuide(context);
    }

    final selectedDate = ref.watch(selectedDateProvider);
    final range = ref.watch(screenUsageTimeRangeProvider);
    final dayAsync = ref.watch(screenUsageDayProvider(selectedDate));
    final rangeAsync = ref.watch(screenUsageRangeProvider(ScreenUsageRangeArg(range, selectedDate)));
    final trendAsync = ref.watch(screenUsageTrendProvider(ScreenUsageTrendArg(range, selectedDate)));
    final earliestAsync = ref.watch(screenUsageEarliestDateProvider);

    return RefreshIndicator(
      onRefresh: () => _checkAndLoad(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          DateNavigationHeader(
            selectedDate: selectedDate,
            onDateChanged: (date) {
              ref.read(selectedDateProvider.notifier).state = date;
            },
          ),
          const SizedBox(height: 12),
          Center(
            child: TimeRangeSelector(
              selectedRange: range,
              onRangeChanged: (value) {
                ref.read(screenUsageTimeRangeProvider.notifier).state = value;
              },
            ),
          ),
          const SizedBox(height: 16),

          dayAsync.when(
            loading: () => _buildSkeletonCard(theme, height: 118),
            error: (err, _) => _buildErrorCard(theme, '读取当日数据失败: $err'),
            data: (day) => day.collected
                ? _buildDayCard(theme, day)
                : _buildNotCollectedCard(theme, day.date, earliestAsync.valueOrNull),
          ),
          const SizedBox(height: 16),

          rangeAsync.when(
            loading: () => _buildSkeletonCard(theme, height: 96),
            error: (err, _) => _buildErrorCard(theme, '读取区间统计失败: $err'),
            data: (agg) => _buildRangeCard(theme, agg, range),
          ),
          const SizedBox(height: 16),

          trendAsync.when(
            loading: () => _buildSkeletonCard(theme, height: 190),
            error: (err, _) => const SizedBox.shrink(),
            data: (trend) => _buildTrendCard(theme, trend, selectedDate, range),
          ),
          const SizedBox(height: 24),

          _buildAppListHeader(theme, range),
          const SizedBox(height: 12),
          rangeAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (err, _) => const SizedBox.shrink(),
            data: (agg) => _buildAppUsageGrid(theme, agg.topApps),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// 授权引导卡片
  Widget _buildPermissionGuide(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 32),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.hourglass_top_rounded, size: 40, color: colorScheme.primary),
          ),
          const SizedBox(height: 20),
          Text(
            '获取健康使用手机数据',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            '需开启「有权查看使用情况的应用」权限，授权后即可回看逐日屏幕时长、周/月聚合与应用排行。'
            '系统只保留最近约 7 天数据，App 会每天自动记录，历史记录从今天起累积。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            icon: const Icon(Icons.security_update_good_rounded),
            label: const Text('去系统设置开启权限'),
            onPressed: () {
              ref.read(screenUsageServiceProvider).requestPermission();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(ThemeData theme, String text, {IconData? icon}) {
    return Row(
      children: [
        if (icon != null) ...[
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 16, color: _accent),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 通用卡片容器：低对比边框 + 背景色差表达层级，不用重阴影
  Widget _buildCard({
    required ThemeData theme,
    required List<Widget> children,
    double? minHeight,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      constraints: minHeight == null ? null : BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1E1E22)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.large),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildSkeletonCard(ThemeData theme, {required double height}) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
    );
  }

  Widget _buildErrorCard(ThemeData theme, String message) {
    return _buildCard(
      theme: theme,
      children: [
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            onPressed: () => _checkAndLoad(force: true),
          ),
        ),
      ],
    );
  }

  /// 所选日概览：大数字 + 较昨日
  Widget _buildDayCard(ThemeData theme, ScreenUsageDayView day) {
    final isDark = theme.brightness == Brightness.dark;
    final title = day.isToday ? '今日屏幕使用时长' : '${formatDayLabel(day.date)}屏幕使用时长';

    return _buildCard(
      theme: theme,
      children: [
        _buildSectionLabel(theme, title, icon: Icons.hourglass_bottom_rounded),
        const SizedBox(height: 12),
        if (!day.hasRecord)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '当天没有使用记录',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else ...[
          Text(
            day.formattedTotal,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 32,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            day.isToday
                ? '${day.diffText}（今日尚未过完，对比的是昨日全天）'
                : day.diffText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white54 : theme.colorScheme.outline,
              fontSize: 13,
            ),
          ),
          // 当日明细：区间应用榜是累计口径，这里保留「这一天用了什么」的原始视角
          if (day.apps.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...day.apps.take(5).map(
                  (app) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            app.appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                          ),
                        ),
                        Text(
                          app.formattedDuration,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color: isDark ? Colors.white60 : theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ],
      ],
    );
  }

  /// 历史日期尚未开始采集时的说明卡
  Widget _buildNotCollectedCard(ThemeData theme, DateTime date, DateTime? earliest) {
    final earliestText = earliest == null
        ? '尚无记录'
        : '${earliest.month}月${earliest.day}日';
    return _buildCard(
      theme: theme,
      children: [
        _buildSectionLabel(theme, '这一天还没有数据', icon: Icons.cloud_off_rounded),
        const SizedBox(height: 12),
        Text(
          '屏幕时长需要逐日记录之后才能回看。本应用的最早记录日期为 $earliestText，'
          '而系统本身只提供最近约 7 天的使用统计，更早的日期无法补回。'
          '从今天起，应用会在启动和回到前台时自动保存每日数据。',
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.6,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 区间概览：总时长 / 日均 / 有记录天数 + 环比
  Widget _buildRangeCard(ThemeData theme, ScreenUsageAggregate agg, TimeRangeType range) {
    final isDark = theme.brightness == Brightness.dark;
    final bounds = agg.bounds;

    return _buildCard(
      theme: theme,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildSectionLabel(
                theme,
                _rangeTitle(range, bounds.start, bounds.dataEnd),
                icon: Icons.calendar_view_week_rounded,
              ),
            ),
            Text(
              _rangeDateText(bounds.start, bounds.dataEnd),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (!agg.hasData)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '本期暂无屏幕使用记录',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildMetric(
                  theme,
                  label: '本期总时长',
                  value: agg.formattedTotal,
                ),
              ),
              Expanded(
                child: _buildMetric(
                  theme,
                  label: '日均',
                  value: agg.formattedAvg,
                  footnote: '按 ${agg.recordedDays} 天计算\n（区间共 ${agg.spanDays} 天）',
                ),
              ),
              Expanded(
                child: _buildMetric(
                  theme,
                  label: '有记录天数',
                  value: '${agg.recordedDays}/${agg.spanDays}',
                ),
              ),
            ],
          ),
        if (agg.hasData) ...[
          const SizedBox(height: 12),
          Text(
            agg.diffText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white54 : theme.colorScheme.outline,
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMetric(
    ThemeData theme, {
    required String label,
    required String value,
    String? footnote,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: isDark ? Colors.white54 : theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        if (footnote != null) ...[
          const SizedBox(height: 2),
          Text(
            footnote,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              height: 1.3,
              color: isDark ? Colors.white38 : theme.colorScheme.outlineVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// 趋势柱状图：粒度随区间变化，未采集日画成空心柱与「真没用机」区分
  Widget _buildTrendCard(
    ThemeData theme,
    ScreenUsageTrend trend,
    DateTime selectedDate,
    TimeRangeType range,
  ) {
    if (trend.isEmpty) {
      return _buildCard(
        theme: theme,
        children: [
          _buildSectionLabel(theme, '趋势', icon: Icons.bar_chart_rounded),
          const SizedBox(height: 12),
          Text(
            '还没有足够的历史记录，应用会每天自动保存当日屏幕时长。',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      );
    }

    return _buildCard(
      theme: theme,
      children: [
        _buildSectionLabel(theme, _trendTitle(range), icon: Icons.bar_chart_rounded),
        const SizedBox(height: 20),
        SizedBox(
          height: 150,
          child: _buildBarChart(theme, trend, selectedDate),
        ),
      ],
    );
  }

  Widget _buildBarChart(ThemeData theme, ScreenUsageTrend trend, DateTime selectedDate) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final points = trend.points;

    // 上限至少 2 小时，避免整段都是分钟级时柱子贴顶失真
    final maxY = (trend.maxHours * 1.25).clamp(2.0, 24.0);
    final labelEvery = points.length > 16 ? 5 : (points.length > 10 ? 3 : 1);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < points.length; i++) {
      final item = points[i];
      final isSelected = _samePeriod(item.date, selectedDate, trend.monthly);
      final color = !item.collected
          ? (isDark ? Colors.white.withValues(alpha: 0.07) : Colors.black.withValues(alpha: 0.06))
          : isSelected
              ? _accent
              : _accent.withValues(alpha: isDark ? 0.75 : 0.6);

      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              // 未采集日用等高淡柱占位，视觉上就是「空的」，不与真实 0 混淆
              toY: item.collected ? item.hours : maxY,
              color: color,
              width: points.length > 16 ? 8 : 22,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(item.collected ? 4 : 2),
              ),
              backDrawRodData: BackgroundBarChartRodData(
                show: true,
                toY: maxY,
                color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03),
              ),
            ),
          ],
        ),
      );
    }

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => isDark ? const Color(0xFF2C2C2E) : colorScheme.surfaceContainerHigh,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              if (groupIndex < 0 || groupIndex >= points.length) {
                return null;
              }
              final item = points[groupIndex];
              final title = trend.monthly
                  ? '${item.date.month}月'
                  : '${item.date.month}月${item.date.day}日';
              final body = item.collected ? formatScreenDuration(item.totalTimeMs) : '未采集';
              return BarTooltipItem(
                '$title\n$body',
                TextStyle(
                  color: isDark ? Colors.white : colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            },
          ),
          // 点柱子直接跳到那一天/那个月，图与头部联动
          touchCallback: (event, response) {
            if (event is! FlTapUpEvent) {
              return;
            }
            final touched = response?.spot?.touchedBarGroupIndex;
            if (touched == null || touched >= points.length) {
              return;
            }
            final date = points[touched].date;
            ref.read(selectedDateProvider.notifier).state = DateTime(date.year, date.month, date.day);
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 56,
              interval: maxY / 2,
              getTitlesWidget: (value, meta) {
                if (value == 0) {
                  return const Text(' 0', style: TextStyle(fontSize: 10, color: Colors.grey));
                }
                final h = value.toInt();
                final m = ((value - h) * 60).round();
                final text = m > 0 ? '$h小时$m分' : '$h小时';
                return Text(' $text', style: const TextStyle(fontSize: 10, color: Colors.grey));
              },
            ),
          ),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= points.length) {
                  return const SizedBox.shrink();
                }
                if (idx % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                final item = points[idx];
                final selected = _samePeriod(item.date, selectedDate, trend.monthly);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _axisLabel(item.date, trend.monthly),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      color: selected
                          ? (isDark ? Colors.white : colorScheme.primary)
                          : (isDark ? Colors.white54 : colorScheme.outline),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 2,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
              strokeWidth: 1,
              dashArray: const [4, 4],
            );
          },
        ),
        borderData: FlBorderData(show: false),
        barGroups: barGroups,
      ),
    );
  }

  /// 应用使用时长列表
  Widget _buildAppUsageGrid(ThemeData theme, List<ScreenAppUsage> apps) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    if (apps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '本期暂无应用使用明细',
            style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 500;
        final crossAxisCount = isWide ? 3 : 2;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 68,
          ),
          itemCount: apps.length,
          itemBuilder: (context, index) {
            final app = apps[index];
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E22) : colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.1),
                  width: 0.5,
                ),
              ),
              child: Row(
                children: [
                  // 区间累计口径下没有图标，用首字母色块代替网格占位图
                  _buildAppAvatar(theme, app),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          app.formattedDuration,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isDark ? Colors.white60 : colorScheme.outline,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAppAvatar(ThemeData theme, ScreenAppUsage app) {
    final hue = app.packageName.hashCode % 360;
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: HSLColor.fromAHSL(1, hue.toDouble(), 0.35, theme.brightness == Brightness.dark ? 0.28 : 0.88)
            .toColor(),
      ),
      child: Text(
        app.appName.isEmpty ? '?' : app.appName.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: HSLColor.fromAHSL(1, hue.toDouble(), 0.5, theme.brightness == Brightness.dark ? 0.82 : 0.32)
              .toColor(),
        ),
      ),
    );
  }

  Widget _buildAppListHeader(ThemeData theme, TimeRangeType range) {
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.bold,
      letterSpacing: 0.2,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(_appListTitle(range), style: titleStyle),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '按区间内逐日累计排序，每日仅保留使用时长前 20 的应用',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }

  bool _samePeriod(DateTime point, DateTime selected, bool monthly) {
    if (monthly) {
      return point.year == selected.year && point.month == selected.month;
    }
    return point.year == selected.year &&
        point.month == selected.month &&
        point.day == selected.day;
  }

  String _axisLabel(DateTime date, bool monthly) {
    if (monthly) {
      return '${date.month}月';
    }
    return shortDayLabel(date);
  }

  String _rangeTitle(TimeRangeType range, DateTime start, DateTime end) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isCurrent = !end.isBefore(today) && !start.isAfter(today);
    if (!isCurrent) {
      return '所选区间屏幕使用时长';
    }
    switch (range) {
      case TimeRangeType.week:
        return '本周屏幕使用时长';
      case TimeRangeType.month:
        return '本月屏幕使用时长';
      case TimeRangeType.year:
        return '本年屏幕使用时长';
    }
  }

  String _trendTitle(TimeRangeType range) {
    switch (range) {
      case TimeRangeType.week:
        return '本周每日趋势';
      case TimeRangeType.month:
        return '本月每日趋势';
      case TimeRangeType.year:
        return '本年逐月趋势';
    }
  }

  String _appListTitle(TimeRangeType range) {
    switch (range) {
      case TimeRangeType.week:
        return '本周应用使用时长';
      case TimeRangeType.month:
        return '本月应用使用时长';
      case TimeRangeType.year:
        return '本年应用使用时长';
    }
  }

  String _rangeDateText(DateTime start, DateTime end) {
    if (start.year != end.year) {
      return '${start.year}/${start.month}/${start.day} - ${end.year}/${end.month}/${end.day}';
    }
    if (start.month != end.month) {
      return '${start.month}/${start.day} - ${end.month}/${end.day}';
    }
    return '${start.month}月${start.day}日-${end.day}日';
  }
}
