import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/storage/statistics_view_store.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/stats_provider.dart';
import 'package:qnote_flutter/widgets/common/motion_reveal.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';
import 'package:qnote_flutter/widgets/drawer_nav_controls.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/time_range_selector.dart';
import 'package:qnote_flutter/widgets/statistics/diet_stats.dart';
import 'package:qnote_flutter/widgets/statistics/finance_stats.dart';
import 'package:qnote_flutter/widgets/statistics/daily_score_stats.dart';
import 'package:qnote_flutter/widgets/statistics/health_stats_view.dart';
import 'package:qnote_flutter/widgets/statistics/insight_card.dart';
import 'package:qnote_flutter/widgets/statistics/screen_usage_stats_view.dart';

class _TabConfig {
  final StatTab tab;

  /// 完整名称，仅用于无障碍朗读；胶囊内显示 [shortLabel] 以适配等宽排布。
  final String label;
  final String shortLabel;
  final IconData icon;

  const _TabConfig({required this.tab, required this.label, required this.shortLabel, required this.icon});
}

const _tabs = [
  _TabConfig(tab: StatTab.score, label: '评分', shortLabel: '评分', icon: Icons.insights_rounded),
  _TabConfig(tab: StatTab.healthDevice, label: '运动健康', shortLabel: '运动', icon: Icons.favorite_rounded),
  _TabConfig(tab: StatTab.screenTime, label: '屏幕时长', shortLabel: '屏幕', icon: Icons.hourglass_top_rounded),
  _TabConfig(tab: StatTab.diet, label: '饮食', shortLabel: '饮食', icon: Icons.restaurant_rounded),
  _TabConfig(tab: StatTab.finance, label: '记账', shortLabel: '记账', icon: Icons.account_balance_wallet_rounded),
];

class StatisticsPage extends ConsumerStatefulWidget {
  const StatisticsPage({super.key});

  @override
  ConsumerState<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends ConsumerState<StatisticsPage> {
  StatTab _activeTab = StatTab.score;
  TimeRangeType _timeRange = TimeRangeType.week;

  /// 分类是否已确定（异步恢复完成或用户主动切换过）。
  ///
  /// 防止 SharedPreferences 还没读完时用户已经点了别的分类，又被旧偏好覆盖。
  bool _tabSettled = false;

  /// 同板块切换「周/月/年」时暂存上一份统计结果，避免短暂 loading 卸载图表导致变形动画中断。
  StatTab? _cachedTab;
  dynamic _cachedStats;
  List<DiaryRecord> _cachedRecords = const [];

  @override
  void initState() {
    super.initState();
    _restoreLastTab();
  }

  /// 恢复上次停留的分类：下次进入（含重启 App）直接回到同一分类。
  Future<void> _restoreLastTab() async {
    final saved = await StatisticsViewStore.loadLastTab();
    if (!mounted || _tabSettled) return;
    _tabSettled = true;
    if (saved == null || saved == _activeTab) return;
    // 只恢复当前仍展示的分类；历史遗留的旧 tab 值直接回退到默认分类
    if (!_tabs.any((config) => config.tab == saved)) return;
    setState(() {
      _activeTab = saved;
      _cachedTab = null;
      _cachedStats = null;
      _cachedRecords = const [];
    });
  }

  void _onTabChanged(StatTab tab) {
    _tabSettled = true;
    if (tab == _activeTab) return;
    setState(() {
      _activeTab = tab;
      _cachedTab = null;
      _cachedStats = null;
      _cachedRecords = const [];
    });
    StatisticsViewStore.saveLastTab(tab);
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

  /// 打开统计明细二级页（记账 → 账单明细，饮食 → 饮食明细）。
  void _openDetail(DateTime startDate, DateTime endDate) {
    final path = _activeTab == StatTab.finance ? '/statistics/ledger' : '/statistics/meals';
    context.push(path, extra: {'start': startDate, 'end': endDate});
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
        // 统计从抽屉一级菜单整页打开：左侧「←」退出并重新拉开抽屉回一级菜单，
        // 「⌂」退出停在主界面，两个目的地并列（见 DrawerPageHomeLeading）
        title: const Text('数据统计'),
        centerTitle: true,
        leading: const DrawerPageHomeLeading(),
        leadingWidth: drawerPageHomeLeadingWidth(context),
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
            // 同板块切换「周/月/年」时保留图表实例，让 fl_chart 平滑形变；
            // 跨板块切换用单子树显现过渡，不双份挂载重图表。
            child: MotionReveal(
              triggerKey: _activeTab,
              beginOpacity: 0.4,
              beginOffsetY: 0.012,
              child: KeyedSubtree(key: ValueKey(_activeTab.name), child: _buildContent(startDate, endDate)),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RepaintBoundary(child: DailyScoreStats()),
            // 空态整卡隐藏：没有足够关联时不会多出一块占位
            InsightCard(),
          ],
        ),
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
    final hasCachedSameTab = _cachedTab == _activeTab && _cachedStats != null;
    final liveRecords = recordsForStatTab(
      ref.watch(diaryListByDateRangeProvider((start: startDate, end: endDate))).valueOrNull ?? const [],
      _activeTab,
    );

    Widget buildDataChild(dynamic stats, List<DiaryRecord> records) {
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
          content = DietStatsWidget(
            stats: stats as DietStatistics,
            records: records,
            onViewAll: () => _openDetail(startDate, endDate),
          );
        case StatTab.finance:
          content = FinanceStatsWidget(
            stats: stats as FinanceStatistics,
            records: records,
            startDate: startDate,
            endDate: endDate,
            onViewAll: () => _openDetail(startDate, endDate),
          );
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
    }

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
        loading: () => hasCachedSameTab
            ? buildDataChild(_cachedStats, _cachedRecords)
            : const Center(key: ValueKey('stats_loading'), child: CircularProgressIndicator()),
        error: (err, stack) => Center(key: const ValueKey('stats_error'), child: Text('统计失败：$err')),
        data: (stats) {
          _cachedTab = _activeTab;
          _cachedStats = stats;
          _cachedRecords = liveRecords;
          return buildDataChild(stats, liveRecords);
        },
      ),
    );
  }
}

class _TabSwitcher extends StatelessWidget {
  final List<_TabConfig> tabs;
  final StatTab activeTab;
  final ValueChanged<StatTab> onTabChanged;

  const _TabSwitcher({required this.tabs, required this.activeTab, required this.onTabChanged});

  /// 单个胶囊低于此宽度时先隐藏图标（只留短标签），避免窄屏把文字压得过小。
  static const double _minChipWidthForIcon = 56;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.2), width: 0.5)),
      ),
      // 改为 5 个等宽胶囊同排：常见手机宽度下无需横向滑动即可看全分类。
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 6.0;
          final chipWidth = (constraints.maxWidth - gap * (tabs.length - 1)) / tabs.length;
          final showIcon = chipWidth >= _minChipWidthForIcon;
          return Row(
            children: [
              for (var i = 0; i < tabs.length; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                Expanded(child: _buildTabChip(context, tabs[i], showIcon: showIcon)),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 单个分类胶囊：等宽紧凑排布，保留图标 + 短标签与按压缩放反馈。
  Widget _buildTabChip(BuildContext context, _TabConfig config, {required bool showIcon}) {
    final colorScheme = Theme.of(context).colorScheme;
    final isActive = config.tab == activeTab;
    final foreground = isActive ? colorScheme.onPrimary : colorScheme.onSurfaceVariant.withValues(alpha: 0.9);

    return Semantics(
      button: true,
      selected: isActive,
      label: config.label,
      excludeSemantics: true,
      child: PressableScale(
        pressedScale: 0.95,
        onTap: () {
          if (isActive) return;
          HapticFeedback.selectionClick();
          onTabChanged(config.tab);
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppDurations.normal),
          curve: AppCurves.standard,
          height: 36,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: isActive ? colorScheme.primary : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isActive
                  ? (Theme.of(context).accentNeedsOutline ? colorScheme.outlineVariant : colorScheme.primary)
                  : colorScheme.outlineVariant.withValues(alpha: 0.45),
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
          // 极窄宽度（如 Web 半屏）下整体等比缩小，保证 5 个分类始终同排不溢出。
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (showIcon) ...[Icon(config.icon, size: 14, color: foreground), const SizedBox(width: 4)],
                AnimatedDefaultTextStyle(
                  duration: AppMotion.duration(context, AppDurations.normal),
                  curve: AppCurves.standard,
                  style: TextStyle(
                    fontSize: AppTypography.bodySmall,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                    letterSpacing: 0.1,
                    color: foreground,
                  ),
                  child: Text(config.shortLabel, maxLines: 1, softWrap: false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
