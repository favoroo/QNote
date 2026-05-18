import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';
import 'package:qnote_flutter/widgets/statistics/sleep_stats.dart';
import 'package:qnote_flutter/widgets/statistics/diet_stats.dart';
import 'package:qnote_flutter/widgets/statistics/finance_stats.dart';
import 'package:qnote_flutter/widgets/statistics/mood_stats.dart';
import 'package:qnote_flutter/widgets/statistics/activity_stats.dart';

enum StatTab { sleep, diet, finance, mood, activity }

class _TabConfig {
  final StatTab tab;
  final String label;
  final IconData icon;
  const _TabConfig({required this.tab, required this.label, required this.icon});
}

const _tabs = [
  _TabConfig(tab: StatTab.sleep, label: '睡眠', icon: Icons.bedtime),
  _TabConfig(tab: StatTab.diet, label: '饮食', icon: Icons.restaurant),
  _TabConfig(tab: StatTab.finance, label: '记账', icon: Icons.account_balance_wallet),
  _TabConfig(tab: StatTab.mood, label: '状态', icon: Icons.favorite),
  _TabConfig(tab: StatTab.activity, label: '活动', icon: Icons.directions_run),
];

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});

  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  StatTab _activeTab = StatTab.sleep;
  TimeRangeType _timeRange = TimeRangeType.week;
  List<DiaryRecord> _records = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void didUpdateWidget(covariant StatisticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final repo = DiaryRepository();
    final now = DateTime.now();
    DateTime startDate;
    switch (_timeRange) {
      case TimeRangeType.week:
        startDate = now.subtract(const Duration(days: 7));
      case TimeRangeType.month:
        startDate = DateTime(now.year, now.month - 1, now.day);
      case TimeRangeType.year:
        startDate = DateTime(now.year - 1, now.month, now.day);
    }
    final records = await repo.getByDateRange(startDate, now);
    if (!mounted) return;
    setState(() {
      _records = records;
      _isLoading = false;
    });
  }

  void _onTabChanged(StatTab tab) {
    if (tab == _activeTab) return;
    setState(() => _activeTab = tab);
  }

  void _onTimeRangeChanged(TimeRangeType range) {
    if (range == _timeRange) return;
    setState(() => _timeRange = range);
    _loadRecords();
  }

  (DateTime, DateTime) _getDateRange() {
    final now = DateTime.now();
    switch (_timeRange) {
      case TimeRangeType.week:
        return (now.subtract(const Duration(days: 7)), now);
      case TimeRangeType.month:
        return (DateTime(now.year, now.month - 1, now.day), now);
      case TimeRangeType.year:
        return (DateTime(now.year - 1, now.month, now.day), now);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final (startDate, endDate) = _getDateRange();

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
            isDark: isDark,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: TimeRangeSelector(
              selectedRange: _timeRange,
              onRangeChanged: _onTimeRangeChanged,
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildContent(startDate, endDate, isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(DateTime startDate, DateTime endDate, bool isDark) {
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bar_chart, size: 48, color: isDark ? const Color(0xFF383C47) : const Color(0xFFC2C6D6)),
            const SizedBox(height: 12),
            Text(
              '暂无数据',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      );
    }

    Widget content;
    switch (_activeTab) {
      case StatTab.sleep:
        final stats = calculateSleepStats(_records, startDate, endDate);
        content = SleepStatsWidget(stats: stats);
      case StatTab.diet:
        final stats = calculateDietStats(_records, startDate, endDate);
        content = DietStatsWidget(stats: stats);
      case StatTab.finance:
        final stats = calculateFinanceStats(_records, startDate, endDate);
        content = FinanceStatsWidget(stats: stats);
      case StatTab.mood:
        final stats = calculateMoodStats(_records, startDate, endDate);
        content = MoodStatsWidget(stats: stats);
      case StatTab.activity:
        final stats = calculateActivityStats(_records, startDate, endDate);
        content = ActivityStatsWidget(stats: stats);
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
  final bool isDark;

  const _TabSwitcher({
    required this.tabs,
    required this.activeTab,
    required this.onTabChanged,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0x1A383C47) : const Color(0x1AC2C6D6),
            width: 0.5,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: tabs.map((config) {
            final isActive = config.tab == activeTab;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => onTabChanged(config.tab),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive ? colorScheme.primary : (isDark ? const Color(0xFF2A2D36) : const Color(0xFFECEDF7)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Center(
                    child: Text(
                      config.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                        color: isActive ? colorScheme.onPrimary : (isDark ? const Color(0xFFC2C6D6) : const Color(0xFF424754)),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
