import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';
import 'package:qnote_flutter/widgets/statistics/sleep_stats.dart';
import 'package:qnote_flutter/widgets/statistics/diet_stats.dart';
import 'package:qnote_flutter/widgets/statistics/finance_stats.dart';
import 'package:qnote_flutter/widgets/statistics/mood_stats.dart';
import 'package:qnote_flutter/widgets/statistics/activity_stats.dart';
import 'package:qnote_flutter/widgets/statistics/daily_score_stats.dart';

enum StatTab { score, sleep, diet, finance, mood, activity }

class _TabConfig {
  final StatTab tab;
  final String label;
  final IconData icon;
  const _TabConfig({
    required this.tab,
    required this.label,
    required this.icon,
  });
}

const _tabs = [
  _TabConfig(tab: StatTab.score, label: '评分', icon: Icons.insights),
  _TabConfig(tab: StatTab.sleep, label: '睡眠', icon: Icons.bedtime),
  _TabConfig(tab: StatTab.diet, label: '饮食', icon: Icons.restaurant),
  _TabConfig(
    tab: StatTab.finance,
    label: '记账',
    icon: Icons.account_balance_wallet,
  ),
  _TabConfig(tab: StatTab.mood, label: '健康', icon: Icons.health_and_safety),
  _TabConfig(tab: StatTab.activity, label: '活动', icon: Icons.directions_run),
];

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});

  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  StatTab _activeTab = StatTab.score;
  TimeRangeType _timeRange = TimeRangeType.week;

  void _onTabChanged(StatTab tab) {
    if (tab == _activeTab) return;
    setState(() => _activeTab = tab);
  }

  void _onTimeRangeChanged(TimeRangeType range) {
    if (range == _timeRange) return;
    setState(() => _timeRange = range);
  }

  (DateTime, DateTime) _getDateRange() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
    switch (_timeRange) {
      case TimeRangeType.week:
        return (todayStart.subtract(const Duration(days: 8)), todayEnd);
      case TimeRangeType.month:
        return (DateTime(now.year, now.month - 1, now.day - 1), todayEnd);
      case TimeRangeType.year:
        return (DateTime(now.year - 1, now.month, now.day - 1), todayEnd);
    }
  }

  String _getTagName(StatTab tab) {
    switch (tab) {
      case StatTab.sleep:
        return '睡眠';
      case StatTab.diet:
        return '饮食';
      case StatTab.finance:
        return '记账';
      case StatTab.mood:
        return '健康';
      case StatTab.activity:
        return '活动';
      default:
        return '';
    }
  }

  Widget _buildViewDataButton(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Tooltip(
      message: '查看数据',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            final (startDate, endDate) = _getDateRange();
            final tagName = _getTagName(_activeTab);
            context.push('/diary/batch', extra: {
              'initialTags': tagName.isNotEmpty ? [tagName] : null,
              'initialDateRange': DateTimeRange(start: startDate, end: endDate),
            });
          },
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: AppDurations.normal,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: colorScheme.primary.withValues(alpha: 0.2),
                width: 1,
              ),
              color: colorScheme.primary.withValues(alpha: 0.05),
            ),
            child: Icon(
              Icons.analytics_outlined,
              size: 20,
              color: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (startDate, endDate) = _getDateRange();
    final diaryListAsync = ref.watch(diaryListProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('数据统计'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          _TabSwitcher(
            tabs: _tabs,
            activeTab: _activeTab,
            onTabChanged: _onTabChanged,
          ),
          if (_activeTab != StatTab.score)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(width: double.infinity),
                  TimeRangeSelector(
                    selectedRange: _timeRange,
                    onRangeChanged: _onTimeRangeChanged,
                  ),
                  Positioned(
                    right: 0,
                    child: _buildViewDataButton(theme),
                  ),
                ],
              ),
            ),
          Expanded(
            child: diaryListAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(child: Text('加载失败: $err')),
              data: (records) {
                return AnimatedSwitcher(
                  duration: AppDurations.medium,
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  child: KeyedSubtree(
                    key: ValueKey(_activeTab),
                    child: _buildContent(records, startDate, endDate),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    List<DiaryRecord> records,
    DateTime startDate,
    DateTime endDate,
  ) {
    if (_activeTab == StatTab.score) {
      return const SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: DailyScoreStats(),
      );
    }

    final filtered = records.where((r) {
      final targetStart = DateTime(startDate.year, startDate.month, startDate.day);
      final targetEnd = DateTime(endDate.year, endDate.month, endDate.day);
      final effectiveDate = r.getEffectiveDate();
      return !effectiveDate.isBefore(targetStart) && !effectiveDate.isAfter(targetEnd);
    }).toList();

    if (filtered.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.bar_chart,
        message: '暂无数据',
      );
    }

    Widget content;
    switch (_activeTab) {
      case StatTab.sleep:
        final stats = calculateSleepStats(records, startDate, endDate);
        content = SleepStatsWidget(stats: stats);
      case StatTab.diet:
        final stats = calculateDietStats(records, startDate, endDate);
        content = DietStatsWidget(stats: stats);
      case StatTab.finance:
        final stats = calculateFinanceStats(records, startDate, endDate);
        content = FinanceStatsWidget(stats: stats);
      case StatTab.mood:
        final stats = calculateMoodStats(records, startDate, endDate);
        content = MoodStatsWidget(stats: stats);
      case StatTab.activity:
        final stats = calculateActivityStats(records, startDate, endDate);
        content = ActivityStatsWidget(stats: stats);
      case StatTab.score:
        content = const DailyScoreStats();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: content,
    );
  }
}

class _TabSwitcher extends StatelessWidget {
  final List<_TabConfig> tabs;
  final StatTab activeTab;
  final ValueChanged<StatTab> onTabChanged;

  const _TabSwitcher({
    required this.tabs,
    required this.activeTab,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: tabs.map((config) {
          final isActive = config.tab == activeTab;
          return Padding(
            padding: const EdgeInsets.only(right: 2),
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onTabChanged(config.tab);
              },
              child: AnimatedContainer(
                duration: AppDurations.normal,
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: isActive
                      ? colorScheme.primary
                      : colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    config.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isActive
                          ? FontWeight.bold
                          : FontWeight.w600,
                      color: isActive
                          ? colorScheme.onPrimary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
