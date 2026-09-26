import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/providers/diary_progress_provider.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
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
  const _TabConfig({
    required this.tab,
    required this.label,
    required this.icon,
  });
}

const _tabs = [
  _TabConfig(tab: StatTab.score, label: '评分', icon: Icons.insights_rounded),
  _TabConfig(
    tab: StatTab.healthDevice,
    label: '运动健康',
    icon: Icons.favorite_rounded,
  ),
  _TabConfig(
    tab: StatTab.screenTime,
    label: '屏幕时长',
    icon: Icons.hourglass_top_rounded,
  ),
  _TabConfig(tab: StatTab.diet, label: '饮食', icon: Icons.restaurant_rounded),
  _TabConfig(
    tab: StatTab.finance,
    label: '记账',
    icon: Icons.account_balance_wallet_rounded,
  ),
];

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});

  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  StatTab _activeTab = StatTab.score;
  TimeRangeType _timeRange = TimeRangeType.week;

  /// 日记页圆环跳来的定位锚点：「记录坚持与评分热力图」卡片。
  final GlobalKey _streakCardKey = GlobalKey();
  bool _streakFocusPending = false;

  /// 逐帧等卡片 RenderObject 就绪的上限，超了就放弃滚动只清意图。
  static const int _kStreakFocusMaxFrames = 10;

  /// 消费「看记录坚持」意图：必要时先切到评分 tab，再把卡片滚进视口。
  ///
  /// go_router 的分支容器是 IndexedStack + Offstage，非激活分支不参与 layout、
  /// ticker 也被冻结，此时对卡片调 ensureVisible 会静默失效；
  /// 所以这里逐帧重试，而不是在卡片组件内部自己滚。
  void _consumeStreakFocus() {
    if (_streakFocusPending) {
      return;
    }
    _streakFocusPending = true;
    _revealStreakCard(_kStreakFocusMaxFrames);
  }

  void _revealStreakCard(int framesLeft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final cardContext = _streakCardKey.currentContext;
      final box = cardContext?.findRenderObject();
      if (cardContext != null &&
          box is RenderBox &&
          box.attached &&
          box.hasSize &&
          TickerMode.valuesOf(cardContext).enabled) {
        Scrollable.ensureVisible(
          cardContext,
          alignment: 0.12,
          duration: AppDurations.slow,
          curve: AppCurves.emphasized,
        );
      } else if (framesLeft <= 0) {
        debugPrint('统计页定位 streak 卡片超时，跳过滚动');
      } else {
        _revealStreakCard(framesLeft - 1);
        return;
      }
      _streakFocusPending = false;
      ref.read(streakFocusProvider.notifier).state = null;
    });
  }

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
              isHealthDevice ? Icons.settings_outlined : Icons.analytics_outlined,
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

    // 日记页圆环与庆祝胶囊「看看统计」都走这里：streak 指标在评分 tab，
    // 停在别的 tab 时先切过去再定位。
    ref.listen(streakFocusProvider, (previous, next) {
      if (next == null) {
        return;
      }
      if (_activeTab != StatTab.score) {
        setState(() => _activeTab = StatTab.score);
      }
      _consumeStreakFocus();
    });

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
          if (_activeTab != StatTab.score && _activeTab != StatTab.screenTime)
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
            child: AnimatedSwitcher(
              duration: AppDurations.medium,
              switchInCurve: AppCurves.emphasized,
              switchOutCurve: AppCurves.exit,
              // 默认 layoutBuilder 为 center 对齐且约束 loose，内容较短的 tab
              // （如饮食）会收缩高度后整体垂直居中，顶部留出大片空白；
              // 改为撑满 + 顶部对齐，短内容贴顶显示，loading 圈仍居中
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  alignment: Alignment.topCenter,
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    ?currentChild,
                  ],
                );
              },
              child: KeyedSubtree(
                key: ValueKey('${_activeTab.name}_${_timeRange.name}'),
                child: _buildContent(startDate, endDate),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(DateTime startDate, DateTime endDate) {
    // score tab 不依赖 statsProvider，由 DailyScoreStats 内部独立处理
    if (_activeTab == StatTab.score) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: DailyScoreStats(streakCardKey: _streakCardKey),
      );
    }
    // healthDevice tab 呈现小米运动健康全量体征监测仪表盘
    if (_activeTab == StatTab.healthDevice) {
      return HealthStatsView(
        startDate: startDate,
        endDate: endDate,
      );
    }
    // screenTime tab 呈现手机屏幕使用时长与应用排行榜（复刻系统健康使用手机）
    if (_activeTab == StatTab.screenTime) {
      return const ScreenUsageStatsView();
    }

    final query = StatsQuery(
      start: startDate,
      end: endDate,
      tab: _activeTab,
    );
    final statsAsync = ref.watch(statsProvider(query));

    return statsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(child: Text('统计计算失败: $err')),
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
          return const EmptyStateWidget(
            icon: Icons.bar_chart,
            message: '暂无数据',
          );
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: RepaintBoundary(child: content),
        );
      },
    );
  }
}

class _TabSwitcher extends StatefulWidget {
  final List<_TabConfig> tabs;
  final StatTab activeTab;
  final ValueChanged<StatTab> onTabChanged;

  const _TabSwitcher({
    required this.tabs,
    required this.activeTab,
    required this.onTabChanged,
  });

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
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
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
        duration: AppDurations.normal,
        curve: Curves.easeInOut,
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive
              ? colorScheme.primary
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: isActive
                ? colorScheme.primary
                : colorScheme.outlineVariant.withValues(alpha: 0.45),
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
              color: isActive
                  ? colorScheme.onPrimary
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
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
                color: isActive
                    ? colorScheme.onPrimary
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
