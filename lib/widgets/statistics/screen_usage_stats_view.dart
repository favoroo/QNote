import 'dart:typed_data';

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
/// 同时挂在「数据统计 → 屏幕时长」tab 与设置页的独立页上。只按周口径统计
/// （周一~周日），不再提供周/月/年切换：月/年视图要按整月累计才能看，柱状图与
/// 榜单的口径都会变，实际使用中没有价值。日期沿用全局 selectedDateProvider，
/// 与评分 tab 保持一致。
class ScreenUsageStatsView extends ConsumerStatefulWidget {
  const ScreenUsageStatsView({super.key});

  @override
  ConsumerState<ScreenUsageStatsView> createState() => ScreenUsageStatsViewState();
}

class ScreenUsageStatsViewState extends ConsumerState<ScreenUsageStatsView> with WidgetsBindingObserver {
  static const Color _accent = Color(0xFF388AF6);

  /// 未采集日占位柱相对 Y 轴上限的高度比例，只作「这里没有数据」的轻微提示
  static const double _uncollectedStubRatio = 0.06;

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
    ref.invalidate(screenUsageWeekAvgProvider);
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
    final dayAsync = ref.watch(screenUsageDayProvider(selectedDate));
    final weekAsync = ref.watch(
      screenUsageRangeProvider(ScreenUsageRangeArg(TimeRangeType.week, selectedDate)),
    );
    final trendAsync = ref.watch(screenUsageTrendProvider(ScreenUsageTrendArg(selectedDate)));
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

          // 本周概览与逐日趋势合并成一张卡：两者说的是同一件事，拆开后页面长一倍
          weekAsync.when(
            loading: () => _buildSkeletonCard(theme, height: 244),
            error: (err, _) => _buildErrorCard(theme, '读取本周统计失败: $err'),
            data: (agg) => _buildWeekCard(theme, agg, trendAsync, selectedDate),
          ),
          const SizedBox(height: 12),

          dayAsync.when(
            loading: () => _buildSkeletonCard(theme, height: 150),
            error: (err, _) => _buildErrorCard(theme, '读取当日数据失败: $err'),
            data: (day) => day.collected
                ? _buildDayCard(theme, day)
                : _buildNotCollectedCard(theme, day.date, earliestAsync.valueOrNull),
          ),
          const SizedBox(height: 12),

          weekAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (err, _) => const SizedBox.shrink(),
            data: (agg) => _buildAppRanking(theme, agg),
          ),
          const SizedBox(height: 24),
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
            '需开启「有权查看使用情况的应用」权限，授权后即可回看每日屏幕时长、本周聚合与应用排行。'
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

  /// 区块标题：图标 + 文案。文案允许被压缩截断，避免与右侧的日期/说明争抢宽度时溢出。
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
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
    EdgeInsetsGeometry padding = const EdgeInsets.all(20),
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      constraints: minHeight == null ? null : BoxConstraints(minHeight: minHeight),
      padding: padding,
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
    final title = day.isToday ? '今日屏幕时长' : '${formatDayLabel(day.date)}屏幕时长';
    final topApps = day.apps.take(5).toList();
    // 历史日回落快照时没有图标字节，按包名回原生补齐
    final icons = ref
        .watch(screenAppIconProvider(_iconKey(topApps.map((e) => e.packageName))))
        .valueOrNull ??
        const <String, Uint8List>{};

    return _buildCard(
      theme: theme,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      children: [
        _buildSectionLabel(theme, title, icon: Icons.hourglass_bottom_rounded),
        const SizedBox(height: 10),
        if (!day.hasRecord)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '当天没有使用记录',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else ...[
          // 大数字与环比同行，省掉一整行高度
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                day.formattedTotal,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 26,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  day.diffText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : theme.colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
          // 当日明细：区间应用榜是累计口径，这里保留「这一天用了什么」的原始视角
          if (topApps.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 4),
            ...topApps.map(
              (app) => _buildAppRow(
                theme,
                packageName: app.packageName,
                appName: app.appName,
                durationText: app.formattedDuration,
                share: day.totalTimeMs > 0 ? app.totalTimeInForegroundMs / day.totalTimeMs : 0,
                iconBytes: app.iconBytes ?? icons[app.packageName],
                iconSize: 24,
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      children: [
        _buildSectionLabel(theme, '这一天还没有数据', icon: Icons.cloud_off_rounded),
        const SizedBox(height: 8),
        Text(
          '屏幕时长要逐日记录后才能回看，最早记录为 $earliestText；'
          '系统本身只保留最近约 7 天，更早的补不回来。',
          style: theme.textTheme.bodySmall?.copyWith(
            height: 1.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 本周概览：总时长 / 日均 / 有记录天数 + 较上周 + 逐日趋势，合并成一张卡
  Widget _buildWeekCard(
    ThemeData theme,
    ScreenUsageAggregate agg,
    AsyncValue<ScreenUsageTrend> trendAsync,
    DateTime selectedDate,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    final bounds = agg.bounds;

    return _buildCard(
      theme: theme,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      children: [
        Row(
          children: [
            Expanded(
              child: _buildSectionLabel(
                theme,
                _weekTitle(bounds.start, bounds.dataEnd),
                icon: Icons.calendar_view_week_rounded,
              ),
            ),
            Text(
              _compactDateText(bounds.start, bounds.dataEnd),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!agg.hasData)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '本周暂无屏幕使用记录',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _buildMetric(
                  theme,
                  label: '本周总时长',
                  value: agg.formattedTotal,
                ),
              ),
              Expanded(
                flex: 3,
                child: _buildMetric(
                  theme,
                  label: '日均',
                  value: agg.formattedAvg,
                  footnote: '按 ${agg.recordedDays} 天计',
                ),
              ),
              Expanded(
                flex: 2,
                child: _buildMetric(
                  theme,
                  label: '有记录天数',
                  value: '${agg.recordedDays}/${agg.spanDays}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            agg.diffText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white54 : theme.colorScheme.outline,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 6),
          _buildSectionLabel(theme, '每日趋势', icon: Icons.bar_chart_rounded),
          const SizedBox(height: 2),
          trendAsync.when(
            loading: () => const SizedBox(height: 104),
            error: (err, _) => const SizedBox.shrink(),
            data: (trend) => trend.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '还没有足够的历史记录，应用会每天自动保存当日屏幕时长。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  )
                : SizedBox(
                    height: 104,
                    child: _buildBarChart(theme, trend, selectedDate),
                  ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 6),
          _buildWeekCompare(theme, selectedDate),
        ],
      ],
    );
  }

  /// 周均时长对比：基准周及其前两次的日均并排成条形，
  /// 快捷按钮直接跳到本周/上周/上上周，箭头可把整个对比窗口往前挪。
  Widget _buildWeekCompare(ThemeData theme, DateTime selectedDate) {
    final colorScheme = theme.colorScheme;
    final offset = ref.watch(screenUsageCompareWeekProvider);
    final baseWeekStart = mondayOf(selectedDate).add(Duration(days: 7 * offset));
    final weeksAsync = ref.watch(screenUsageWeekAvgProvider(baseWeekStart));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildSectionLabel(
                theme,
                '周均时长对比',
                icon: Icons.timeline_rounded,
              ),
            ),
            _buildWeekArrow(
              theme,
              icon: Icons.chevron_left_rounded,
              enabled: offset > -12,
              onTap: () => _shiftCompareWeek(-1),
            ),
            _buildWeekArrow(
              theme,
              icon: Icons.chevron_right_rounded,
              enabled: offset < 0,
              onTap: () => _shiftCompareWeek(1),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _buildWeekChip(theme, '本周', 0, offset),
            const SizedBox(width: 6),
            _buildWeekChip(theme, '上周', -1, offset),
            const SizedBox(width: 6),
            _buildWeekChip(theme, '上上周', -2, offset),
          ],
        ),
        weeksAsync.when(
          loading: () => const SizedBox(height: 72),
          error: (err, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '读取周均数据失败',
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ),
          data: (weeks) {
            final maxAvgMs = weeks.fold<int>(
              0,
              (m, e) => e.avgMs > m ? e.avgMs : m,
            );
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: [
                  for (final week in weeks)
                    _buildWeekAvgRow(theme, week, maxAvgMs, isBase: week.weekStart == baseWeekStart),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// 一行周均对比：周标签 + 相对最长周的条形 + 日均时长
  Widget _buildWeekAvgRow(
    ThemeData theme,
    ScreenUsageWeekAvg week,
    int maxAvgMs, {
    required bool isBase,
  }) {
    final colorScheme = theme.colorScheme;
    final ratio = maxAvgMs > 0 ? week.avgMs / maxAvgMs : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              _weekLabel(week.weekStart),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                fontWeight: isBase ? FontWeight.w700 : FontWeight.w500,
                color: isBase ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: week.hasData
                ? _buildShareBar(theme, ratio)
                : Text(
                    '无记录',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: colorScheme.outline,
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Text(
            week.hasData ? week.formattedAvg : '-',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              fontWeight: isBase ? FontWeight.w700 : FontWeight.w500,
              color: isBase ? colorScheme.onSurface : colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  /// 对比基准周的快捷按钮，样式与日期导航的「前天/昨天/今天」保持同一族
  Widget _buildWeekChip(ThemeData theme, String label, int targetOffset, int currentOffset) {
    final colorScheme = theme.colorScheme;
    final selected = targetOffset == currentOffset;
    return GestureDetector(
      onTap: () =>
          ref.read(screenUsageCompareWeekProvider.notifier).state = targetOffset,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? colorScheme.primary.withValues(alpha: 0.5)
                : colorScheme.outlineVariant,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 对比窗口平移箭头
  Widget _buildWeekArrow(
    ThemeData theme, {
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final colorScheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? colorScheme.onSurfaceVariant : colorScheme.outlineVariant,
        ),
      ),
    );
  }

  void _shiftCompareWeek(int delta) {
    final next = (ref.read(screenUsageCompareWeekProvider) + delta).clamp(-12, 0);
    ref.read(screenUsageCompareWeekProvider.notifier).state = next;
  }

  /// 周标签：以今天所在周为基准说「本周/上周/上上周」，更早的按「N周前」，再远退化成周一日期
  String _weekLabel(DateTime weekStart) {
    final now = DateTime.now();
    final thisWeekStart = mondayOf(DateTime(now.year, now.month, now.day));
    final weeksAgo = thisWeekStart.difference(weekStart).inDays ~/ 7;
    switch (weeksAgo) {
      case <= 0:
        return '本周';
      case 1:
        return '上周';
      case 2:
        return '上上周';
      case < 10:
        return '$weeksAgo周前';
      default:
        return '${weekStart.month}/${weekStart.day}';
    }
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
            fontSize: 11,
            color: isDark ? Colors.white54 : theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
        if (footnote != null) ...[
          const SizedBox(height: 1),
          Text(
            footnote,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              height: 1.2,
              color: isDark ? Colors.white38 : theme.colorScheme.outlineVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBarChart(ThemeData theme, ScreenUsageTrend trend, DateTime selectedDate) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final points = trend.points;

    // Y 轴上限：单日不可能超过 24 小时，同时给分钟级数据留 2 小时下限，
    // 刻度取整洁小时数，保证右侧标签与网格线落在整数上、柱子不会顶到边框。
    final maxY = niceHourCeiling(trend.maxHours * 1.25).clamp(2.0, 24.0);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < points.length; i++) {
      final item = points[i];
      final isSelected = _sameDay(item.date, selectedDate);
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
              // 未采集日只画一小段淡色底柱占位，整根淡柱会让空白天看起来比真实数据更高；
              // 真实值再按 maxY 兜底截断，保证任何脏数据下柱子都不会溢出卡片。
              toY: item.collected
                  ? item.hours.clamp(0.0, maxY)
                  : (maxY * _uncollectedStubRatio).clamp(0.0, maxY),
              color: color,
              width: 20,
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
              final body = item.collected ? formatScreenDuration(item.totalTimeMs) : '未采集';
              return BarTooltipItem(
                '${_weekdayLabel(item.date)} ${shortDayLabel(item.date)}\n$body',
                TextStyle(
                  color: isDark ? Colors.white : colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            },
          ),
          // 点柱子直接跳到那一天，图与头部日期联动
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
              reservedSize: 44,
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
              reservedSize: 20,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= points.length) {
                  return const SizedBox.shrink();
                }
                final item = points[idx];
                final selected = _sameDay(item.date, selectedDate);
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _weekdayLabel(item.date),
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

  /// 本周应用榜：Top 8 紧凑行式（图标 + 名称 + 占比条 + 时长）。
  ///
  /// 原来是 30 条两列格子，光这一段就要滚十几屏；占比条让「谁用得多」一眼可读，
  /// 只留前 8 名即可覆盖绝大部分时长。
  Widget _buildAppRanking(ThemeData theme, ScreenUsageAggregate agg) {
    final apps = agg.topApps.take(8).toList();
    if (apps.isEmpty) {
      return const SizedBox.shrink();
    }

    // 榜单来自逐日快照，快照只存包名/名称/时长，图标按包名回原生批量补齐
    final icons = ref
        .watch(screenAppIconProvider(_iconKey(apps.map((e) => e.packageName))))
        .valueOrNull ??
        const <String, Uint8List>{};

    return _buildCard(
      theme: theme,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      children: [
        _buildSectionLabel(
          theme,
          '本周应用时长 Top ${apps.length}',
          icon: Icons.apps_rounded,
        ),
        const SizedBox(height: 4),
        ...apps.map(
          (app) => _buildAppRow(
            theme,
            packageName: app.packageName,
            appName: app.appName,
            durationText: app.formattedDuration,
            share: agg.totalMs > 0 ? app.timeMs / agg.totalMs : 0,
            iconBytes: icons[app.packageName],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '每日仅记录使用时长前 20 的应用，按本周累计排序',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10,
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  /// 紧凑应用行：图标 + 名称与占比条 + 时长，占比按所在榜单的总量计算
  Widget _buildAppRow(
    ThemeData theme, {
    required String packageName,
    required String appName,
    required String durationText,
    required double share,
    Uint8List? iconBytes,
    double iconSize = 26,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // 未安装/取图失败时回落到首字母色块
          _buildAppIcon(
            theme,
            packageName: packageName,
            appName: appName,
            bytes: iconBytes,
            size: iconSize,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                _buildShareBar(theme, share),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            durationText,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: isDark ? Colors.white60 : theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  /// 占比条：把「谁占得多」变成长度对比，比一串百分比数字更快读
  Widget _buildShareBar(ThemeData theme, double share) {
    final ratio = share.clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Container(
              height: 4,
              width: constraints.maxWidth,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (ratio > 0)
              Container(
                height: 4,
                width: constraints.maxWidth * ratio,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 图标 family 的 key：一批包名拼成稳定字符串，便于 Riverpod 比较与复用缓存
  String _iconKey(Iterable<String> packageNames) => packageNames.join(',');

  /// 应用图标：优先用数据自带的图标字节或按包名补齐的图标，
  /// 取不到（未安装、原生取图失败、Web/iOS 不支持）时落到首字母色块
  Widget _buildAppIcon(
    ThemeData theme, {
    required String packageName,
    required String appName,
    Uint8List? bytes,
    double size = 42,
  }) {
    if (bytes == null || bytes.isEmpty) {
      return _buildLetterAvatar(
        theme,
        packageName: packageName,
        appName: appName,
        size: size,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 同一包名刷新时沿用旧图，避免图标闪一下
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _buildLetterAvatar(
          theme,
          packageName: packageName,
          appName: appName,
          size: size,
        ),
      ),
    );
  }

  /// 首字母色块兜底：按包名取色，保证同一应用的颜色稳定
  Widget _buildLetterAvatar(
    ThemeData theme, {
    required String packageName,
    required String appName,
    required double size,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final hue = packageName.hashCode % 360;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        color: HSLColor.fromAHSL(1, hue.toDouble(), 0.35, isDark ? 0.28 : 0.88).toColor(),
      ),
      child: Text(
        appName.isEmpty ? '?' : appName.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w700,
          color: HSLColor.fromAHSL(1, hue.toDouble(), 0.5, isDark ? 0.82 : 0.32).toColor(),
        ),
      ),
    );
  }

  bool _sameDay(DateTime point, DateTime selected) =>
      point.year == selected.year &&
      point.month == selected.month &&
      point.day == selected.day;

  /// 柱标签用星期（今天显示「今日」），比 M月d日 更短也更好扫读
  String _weekdayLabel(DateTime date) {
    if (_sameDay(date, DateTime.now())) {
      return '今日';
    }
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return labels[date.weekday - 1];
  }

  /// 区间标题：所选日落在本周时说「本周」，回看历史周时说「所选周」
  String _weekTitle(DateTime start, DateTime dataEnd) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isCurrent = !dataEnd.isBefore(today) && !start.isAfter(today);
    return isCurrent ? '本周屏幕时长' : '所选周屏幕时长';
  }

  /// 卡片右上角的区间日期：一律用 M/d 紧凑写法，给标题让出宽度
  String _compactDateText(DateTime start, DateTime end) {
    if (start.year != end.year) {
      return '${start.year}/${start.month}/${start.day} - ${end.year}/${end.month}/${end.day}';
    }
    return '${start.month}/${start.day} - ${end.month}/${end.day}';
  }
}
