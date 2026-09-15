import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import 'package:qnote_flutter/core/health/screen_usage_service.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';

class ScreenUsageStatsView extends ConsumerStatefulWidget {
  const ScreenUsageStatsView({super.key});

  @override
  ConsumerState<ScreenUsageStatsView> createState() => _ScreenUsageStatsViewState();
}

class _ScreenUsageStatsViewState extends ConsumerState<ScreenUsageStatsView> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _hasPermission = false;
  TodayScreenUsage? _todayUsage;
  List<DailyScreenTime> _weeklyList = [];

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
    // 当从系统「有权查看使用情况的应用」授权设置页返回应用前台时，自动重新检查并加载数据
    if (state == AppLifecycleState.resumed) {
      _checkAndLoad();
    }
  }

  Future<void> _checkAndLoad() async {
    final service = ref.read(screenUsageServiceProvider);
    if (!service.isSupported) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final authed = await service.hasPermission();
    if (!authed) {
      if (mounted) {
        setState(() {
          _hasPermission = false;
          _isLoading = false;
        });
      }
      return;
    }

    final today = await service.getTodayUsage(limit: 30);
    final weekly = await service.getWeeklyScreenTime();

    if (mounted) {
      setState(() {
        _hasPermission = true;
        _todayUsage = today;
        _weeklyList = weekly;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
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

    final usage = _todayUsage;
    if (usage == null || (usage.totalTimeMs == 0 && usage.appList.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_empty_rounded, size: 48, color: colorScheme.outline),
            const SizedBox(height: 12),
            Text('今日暂无应用使用记录', style: TextStyle(color: colorScheme.outline)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('刷新'),
              onPressed: _checkAndLoad,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _checkAndLoad,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 顶部今日屏幕使用时长与趋势大卡片（对齐系统截图）
            _buildTodayOverviewCard(context, usage, isDark),
            const SizedBox(height: 24),

            // 2. 应用使用时长排行榜标头
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '应用使用时长',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),

            // 3. 应用时长列表卡片
            _buildAppUsageList(context, usage),
            const SizedBox(height: 32),
          ],
        ),
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
            '需开启「有权查看使用情况的应用」权限，授权后即可在本页查看今日屏幕总时长、各应用详细时长排行榜与周趋势。',
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

  /// 今日使用时长主卡片（含大标题、较昨日增减、柱状图）
  Widget _buildTodayOverviewCard(BuildContext context, TodayScreenUsage usage, bool isDark) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.large),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.15),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标签头
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFF388AF6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.hourglass_bottom_rounded, size: 16, color: Color(0xFF388AF6)),
              ),
              const SizedBox(width: 8),
              Text(
                '今日屏幕使用时长',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 大数字时长
          Text(
            usage.formattedTotalTime,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 32,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),

          // 较昨日增减提示
          Text(
            usage.diffDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white54 : colorScheme.outline,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),

          // 近 7 天趋势柱状图
          if (_weeklyList.isNotEmpty)
            SizedBox(
              height: 130,
              child: _buildBarChart(context, isDark),
            ),
        ],
      ),
    );
  }

  /// 绘制近 7 天柱状图
  Widget _buildBarChart(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 找出 7 天中的最大时长用于确定 Y 轴上限
    double maxHours = 1.0;
    for (final day in _weeklyList) {
      if (day.hours > maxHours) {
        maxHours = day.hours;
      }
    }
    // 上限向上取整到合适的值
    final maxY = (maxHours * 1.25).clamp(2.0, 24.0);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < _weeklyList.length; i++) {
      final item = _weeklyList[i];
      final isToday = item.isToday;

      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: item.hours,
              color: isToday
                  ? const Color(0xFF388AF6) // 截图原版亮蓝色
                  : const Color(0xFF388AF6).withValues(alpha: isDark ? 0.75 : 0.6),
              width: 22,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
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
              if (groupIndex < 0 || groupIndex >= _weeklyList.length) return null;
              final item = _weeklyList[groupIndex];
              return BarTooltipItem(
                '${item.dayLabel}\n${item.hours >= 1.0 ? '${item.hours.toStringAsFixed(1)}小时' : '${item.minutes}分钟'}',
                TextStyle(
                  color: isDark ? Colors.white : colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            },
          ),
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
                if (idx < 0 || idx >= _weeklyList.length) return const SizedBox.shrink();
                final item = _weeklyList[idx];
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    item.dayLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: item.isToday ? FontWeight.bold : FontWeight.normal,
                      color: item.isToday
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
              dashArray: [4, 4],
            );
          },
        ),
        borderData: FlBorderData(show: false),
        barGroups: barGroups,
      ),
    );
  }

  /// 构建各应用使用时长网格/列表（复刻截图双列展示与图标）
  Widget _buildAppUsageList(BuildContext context, TodayScreenUsage usage) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final apps = usage.appList;
    if (apps.isEmpty) {
      return const SizedBox.shrink();
    }

    // 两列并排展示（与截图风格一致）
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
                  // App 图标
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: app.iconBytes != null && app.iconBytes!.isNotEmpty
                          ? Image.memory(
                              app.iconBytes!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => _buildFallbackIcon(colorScheme),
                            )
                          : _buildFallbackIcon(colorScheme),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // 应用名与时长
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

  Widget _buildFallbackIcon(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.primaryContainer.withValues(alpha: 0.4),
      child: Icon(Icons.apps_rounded, size: 22, color: colorScheme.primary),
    );
  }
}
