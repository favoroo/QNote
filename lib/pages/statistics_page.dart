import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/providers/stats_provider.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';
import 'package:qnote_flutter/widgets/statistics/diet_stats.dart';
import 'package:qnote_flutter/widgets/statistics/finance_stats.dart';
import 'package:qnote_flutter/widgets/statistics/daily_score_stats.dart';
import 'package:qnote_flutter/widgets/statistics/health_stats_view.dart';
import 'package:qnote_flutter/widgets/statistics/screen_usage_stats_view.dart';

class _TabConfig {
  final StatTab tab;
  final String label;
  final IconData icon;
  const _TabConfig({required this.tab, required this.label, required this.icon});
}

const _tabs = [
  _TabConfig(tab: StatTab.score, label: '评分', icon: Icons.insights_rounded),
  _TabConfig(tab: StatTab.healthDevice, label: '运动健康', icon: Icons.favorite_rounded),
  _TabConfig(tab: StatTab.screenTime, label: '屏幕时长', icon: Icons.hourglass_top_rounded),
  _TabConfig(tab: StatTab.diet, label: '饮食', icon: Icons.restaurant_rounded),
  _TabConfig(tab: StatTab.finance, label: '记账', icon: Icons.account_balance_wallet_rounded),
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
      case StatTab.diet:
        return '饮食';
      case StatTab.finance:
        return '记账';
      default:
        return '';
    }
  }

  Widget _buildViewDataButton(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final isHealthDevice = _activeTab == StatTab.healthDevice;
    return Tooltip(
      message: isHealthDevice ? '小米健康设置' : '查看数据',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (isHealthDevice) {
              context.push('/settings/mi-fitness');
              return;
            }
            final (startDate, endDate) = _getDateRange();
            final tagName = _getTagName(_activeTab);
            context.push(
              '/diary/batch',
              extra: {
                'initialTags': tagName.isNotEmpty ? [tagName] : null,
                'initialDateRange': DateTimeRange(start: startDate, end: endDate),
              },
            );
          },
          customBorder: const CircleBorder(),
          // 右上入口改实心主题色圆钮：淡描边圆在荧光黄绿下几乎隐形
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppDurations.normal),
            curve: AppCurves.standard,
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: colorScheme.primary),
            child: Icon(
              isHealthDevice ? Icons.settings_outlined : Icons.analytics_outlined,
              size: 20,
              color: colorScheme.onPrimary,
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

    return Scaffold(
      appBar: AppBar(
        // 统计已改为根路由全屏打开，返回按钮由 AppBar 自动提供
        title: const Text('数据统计'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          _TabSwitcher(tabs: _tabs, activeTab: _activeTab, onTabChanged: _onTabChanged),
          AnimatedCrossFade(
            duration: AppMotion.duration(context, AppDurations.normal),
            sizeCurve: AppCurves.emphasized,
            firstCurve: AppCurves.exit,
            secondCurve: AppCurves.emphasized,
            crossFadeState: (_activeTab != StatTab.score && _activeTab != StatTab.screenTime)
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            alignment: Alignment.topCenter,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const SizedBox(width: double.infinity),
                  TimeRangeSelector(selectedRange: _timeRange, onRangeChanged: _onTimeRangeChanged),
                  Positioned(right: 0, child: _buildViewDataButton(theme)),
                ],
              ),
            ),
          ),
          Expanded(
            // 图表区不再包 AnimatedSwitcher：它会让新旧两份重图表同时挂载并
            // 交叉淡入（StackFit.expand 还会强制双份布局），切 tab / 时间范围时
            // 明显掉帧。这里按 key 直接替换子树，状态间的轻量淡入交给
            // _buildContent 内那层只监听 AsyncValue 的 AnimatedSwitcher。
            child: KeyedSubtree(
              key: ValueKey('${_activeTab.name}_${_timeRange.name}'),
              child: _buildContent(startDate, endDate),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(DateTime startDate, DateTime endDate) {
    // score tab 不依赖 statsProvider，由 DailyScoreStats 内部独立处理
    if (_activeTab == StatTab.score) {
      return const SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: RepaintBoundary(child: DailyScoreStats()),
      );
    }
    // healthDevice tab 呈现小米运动健康全量体征监测仪表盘
    if (_activeTab == StatTab.healthDevice) {
      return RepaintBoundary(
        child: HealthStatsView(startDate: startDate, endDate: endDate),
      );
    }
    // screenTime tab 呈现手机屏幕使用时长与应用排行榜（复刻系统健康使用手机）
    if (_activeTab == StatTab.screenTime) {
      return const RepaintBoundary(child: ScreenUsageStatsView());
    }

    final query = StatsQuery(start: startDate, end: endDate, tab: _activeTab);
    final statsAsync = ref.watch(statsProvider(query));

    // 图表区唯一的淡入层：只在 loading / error / empty / data 之间切换时使用，
    // 此时对侧要么是轻量占位、要么只有一张图表，不会出现两张重图表同时布局。
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppDurations.normal),
      switchInCurve: AppCurves.emphasized,
      switchOutCurve: AppCurves.exit,
      // 默认 layoutBuilder 为 center 对齐且约束 loose，内容较短的 tab
      // （如饮食）会收缩高度后整体垂直居中，顶部留出大片空白；
      // 改为撑满 + 顶部对齐，短内容贴顶显示，loading 圈仍居中
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          fit: StackFit.expand,
          children: [...previousChildren, ?currentChild],
        );
      },
      child: statsAsync.when(
        loading: () => const Center(key: ValueKey('stats_loading'), child: CircularProgressIndicator()),
        error: (err, stack) => Center(key: const ValueKey('stats_error'), child: Text('统计失败：$err')),
        data: (stats) {
          // 数据为空时返回 EmptyState（依赖 stats 内部 totalRecords 判断）
          final bool isEmpty;
          switch (_activeTab) {
            case StatTab.diet:
              isEmpty = (stats as DietStatistics).totalMeals == 0;
            case StatTab.finance:
              isEmpty = (stats as FinanceStatistics).totalRecords == 0;
            case StatTab.score:
            case StatTab.healthDevice:
            case StatTab.screenTime:
            case StatTab.sleep:
            case StatTab.mood:
            case StatTab.activity:
              isEmpty = true; // 不会执行到这里
          }
          if (isEmpty) {
            return const EmptyStateWidget(key: ValueKey('stats_empty'), icon: Icons.bar_chart, message: '暂无数据');
          }

          Widget content;
          switch (_activeTab) {
            case StatTab.diet:
              content = DietStatsWidget(stats: stats as DietStatistics);
            case StatTab.finance:
              content = FinanceStatsWidget(stats: stats as FinanceStatistics);
            case StatTab.score:
            case StatTab.healthDevice:
            case StatTab.screenTime:
            case StatTab.sleep:
            case StatTab.mood:
            case StatTab.activity:
              content = const SizedBox.shrink(); // 不会执行到这里
          }

          // 隔离统计卡片的重绘，fl_chart 动画跑动时不影响外部
          return SingleChildScrollView(
            key: const ValueKey('stats_data'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: RepaintBoundary(child: content),
          );
        },
      ),
    );
  }
}

class _TabSwitcher extends StatefulWidget {
  final List<_TabConfig> tabs;
  final StatTab activeTab;
  final ValueChanged<StatTab> onTabChanged;

  const _TabSwitcher({required this.tabs, required this.activeTab, required this.onTabChanged});

  @override
  State<_TabSwitcher> createState() => _TabSwitcherState();
}

class _TabSwitcherState extends State<_TabSwitcher> {
  final ScrollController _scrollController = ScrollController();
  final Map<StatTab, GlobalKey> _tabKeys = {};

  @override
  void initState() {
    super.initState();
    for (final tab in widget.tabs) {
      _tabKeys[tab.tab] = GlobalKey();
    }
  }

  @override
  void didUpdateWidget(covariant _TabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTab != widget.activeTab) {
      _scrollToActiveTab();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _tabKeys[widget.activeTab];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: AppDurations.normal,
          curve: AppCurves.emphasized,
          alignment: 0.5,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.2), width: 0.5)),
      ),
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _buildTabChip(context, widget.tabs[i]),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个分类胶囊按钮：图文排版、平滑过渡、触感反馈、永不换行截断
  Widget _buildTabChip(BuildContext context, _TabConfig config) {
    final colorScheme = Theme.of(context).colorScheme;
    final isActive = config.tab == widget.activeTab;

    return GestureDetector(
      key: _tabKeys[config.tab],
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTabChanged(config.tab);
      },
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppDurations.normal),
        curve: AppCurves.standard,
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive ? colorScheme.primary : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: isActive ? colorScheme.primary : colorScheme.outlineVariant.withValues(alpha: 0.45),
            width: 1,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: colorScheme.primary.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              config.icon,
              size: 15,
              color: isActive ? colorScheme.onPrimary : colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
            const SizedBox(width: 5),
            Text(
              config.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                letterSpacing: 0.2,
                color: isActive ? colorScheme.onPrimary : colorScheme.onSurfaceVariant.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
