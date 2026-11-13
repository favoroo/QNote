import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/models/daily_score.dart';

/// 评分热力图组件（GitHub 贡献图风格）
///
/// 每个方格代表一天，分数越高颜色越深。
/// 使用主题色 colorScheme.primary 配合 alpha 透明度实现深浅变化。
/// 使用 LayoutBuilder 自适应容器宽度，移动端和 Web 端均可正常显示。
class ScoreHeatmap extends StatefulWidget {
  final List<DailyScore> scores;
  final bool isDark;

  const ScoreHeatmap({super.key, required this.scores, required this.isDark});

  @override
  State<ScoreHeatmap> createState() => _ScoreHeatmapState();
}

class _ScoreHeatmapState extends State<ScoreHeatmap> {
  static const double _cellSize = 12;
  static const double _cellGap = 4;
  static const double _weekdayLabelWidth = 20;
  static const double _monthLabelHeight = 20;
  // 月份标签最小间距（像素），避免重叠
  static const double _monthLabelMinGap = 36;

  // OverlayEntry 用于全屏 tooltip + ModalBarrier 实现点击任意位置消失
  OverlayEntry? _overlayEntry;
  GlobalKey<_HeatmapTooltipOverlayState>? _tooltipKey;
  VoidCallback? _forceRemoveOverlay;
  int? _selectedRow;
  int? _selectedCol;

  Color _getCellColor(Color primary, int score) {
    if (score >= 76) return primary.withValues(alpha: 1.0);
    if (score >= 51) return primary.withValues(alpha: 0.6);
    if (score >= 26) return primary.withValues(alpha: 0.35);
    return primary.withValues(alpha: 0.15);
  }

  void _dismissTooltip({bool immediate = false}) {
    final entry = _overlayEntry;
    final state = _tooltipKey?.currentState;
    _overlayEntry = null;
    _tooltipKey = null;

    if (mounted && (_selectedRow != null || _selectedCol != null)) {
      setState(() {
        _selectedRow = null;
        _selectedCol = null;
      });
    }

    if (entry != null) {
      if (immediate || state == null) {
        entry.remove();
        _forceRemoveOverlay = null;
      } else {
        void finish() {
          entry.remove();
          if (_forceRemoveOverlay == finish) {
            _forceRemoveOverlay = null;
          }
        }

        _forceRemoveOverlay = finish;
        state.dismiss().then((_) => _forceRemoveOverlay == finish ? finish() : null);
      }
    } else if (immediate) {
      _forceRemoveOverlay?.call();
      _forceRemoveOverlay = null;
    }
  }

  @override
  void dispose() {
    _dismissTooltip(immediate: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final emptyColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.3);

    if (widget.scores.isEmpty) {
      return SizedBox(
        height: _monthLabelHeight + 7 * (_cellSize + _cellGap) + 24 + 32,
        child: Center(
          child: Text('暂无评分', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }

    // 构建日期 → 分数的映射
    final scoreMap = <String, int>{};
    for (final s in widget.scores) {
      final key = '${s.date.year}-${s.date.month.toString().padLeft(2, '0')}-${s.date.day.toString().padLeft(2, '0')}';
      scoreMap[key] = s.totalScore;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用宽度 = 容器宽度 - 星期标签列宽 - 间距
        final availableWidth = constraints.maxWidth - _weekdayLabelWidth - 8;
        // 根据可用宽度计算最大周数
        final maxWeeks = (availableWidth / (_cellSize + _cellGap)).floor().clamp(4, 100);

        // 计算日期范围：从最近一个周日往前推 maxWeeks 周
        final today = DateTime.now();
        final todayDate = DateTime(today.year, today.month, today.day);
        final endDate = todayDate.add(Duration(days: 7 - todayDate.weekday));
        final startDate = endDate.subtract(Duration(days: 7 * maxWeeks - 1));
        final adjustedStart = startDate.subtract(Duration(days: startDate.weekday - 1));

        // 生成所有天的列表
        final days = <DateTime>[];
        var current = adjustedStart;
        while (current.isBefore(endDate) || current.isAtSameMomentAs(endDate)) {
          days.add(current);
          current = current.add(const Duration(days: 1));
        }

        // 按周分组
        final weeks = <List<DateTime>>[];
        List<DateTime>? currentWeek;
        for (final day in days) {
          if (day.weekday == DateTime.monday || currentWeek == null) {
            currentWeek = [];
            weeks.add(currentWeek);
          }
          currentWeek.add(day);
        }

        final weekCount = weeks.length;

        // 月份标签：碰撞检测避免重叠
        final monthLabels = <(int weekIdx, String label, double leftPx)>[];
        String? lastMonth;
        double lastLeftPx = -_monthLabelMinGap;
        for (var w = 0; w < weekCount; w++) {
          final weekDays = weeks[w];
          if (weekDays.isEmpty) continue;
          final midDay = weekDays[weekDays.length ~/ 2];
          final monthKey = '${midDay.year}-${midDay.month}';
          if (monthKey != lastMonth) {
            final leftPx = w * (_cellSize + _cellGap);
            if (leftPx - lastLeftPx >= _monthLabelMinGap) {
              monthLabels.add((w, '${midDay.month}月', leftPx));
              lastLeftPx = leftPx;
              lastMonth = monthKey;
            }
          }
        }

        // 星期标签（中文）
        final weekdayLabels = [(1, '一'), (3, '三'), (5, '五')];

        // 计算网格实际宽度
        final gridWidth = weekCount * _cellSize + (weekCount - 1) * _cellGap;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: _monthLabelHeight),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 星期标签列
                SizedBox(
                  width: _weekdayLabelWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var row = 0; row < 7; row++) ...[
                        if (row > 0) const SizedBox(height: _cellGap),
                        SizedBox(
                          height: _cellSize,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              weekdayLabels.firstWhere((e) => e.$1 == (row + 1), orElse: () => (row + 1, '')).$2,
                              style: TextStyle(
                                fontSize: AppTypography.micro,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 网格区域 - 使用固定宽度避免拉伸
                SizedBox(
                  width: gridWidth,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 月份标签
                      ...monthLabels.map((ml) {
                        return Positioned(
                          top: -_monthLabelHeight + 4,
                          left: ml.$3,
                          child: Text(
                            ml.$2,
                            style: TextStyle(fontSize: AppTypography.micro, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        );
                      }),
                      // 用 Column + Row 绘制网格，确保 7 行 × N 列
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var row = 0; row < 7; row++) ...[
                            if (row > 0) const SizedBox(height: _cellGap),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var col = 0; col < weekCount; col++) ...[
                                  if (col > 0) const SizedBox(width: _cellGap),
                                  _buildCell(weeks[col], row, col, scoreMap, primary, emptyColor, theme),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildLegend(primary, emptyColor, theme),
          ],
        );
      },
    );
  }

  Widget _buildCell(
    List<DateTime> week,
    int row,
    int col,
    Map<String, int> scoreMap,
    Color primary,
    Color emptyColor,
    ThemeData theme,
  ) {
    if (row >= week.length) {
      return const SizedBox(width: _cellSize, height: _cellSize);
    }

    final day = week[row];
    final key = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final score = scoreMap[key];
    final color = score != null ? _getCellColor(primary, score) : emptyColor;
    final isSelected = _selectedRow == row && _selectedCol == col;

    return GestureDetector(
      onTap: () {
        _dismissTooltip(immediate: true);
        setState(() {
          _selectedRow = row;
          _selectedCol = col;
        });
        _showOverlayTooltip(day, score, theme);
      },
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppDurations.fast),
        curve: AppCurves.standard,
        width: _cellSize,
        height: _cellSize,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
          border: isSelected ? Border.all(color: primary, width: 1.5) : null,
        ),
      ),
    );
  }

  void _showOverlayTooltip(DateTime day, int? score, ThemeData theme) {
    final dateStr = DateFormat('M月d日').format(day);
    final scoreStr = score != null ? '$score 分' : '未评分';

    // 获取 heatmap 在屏幕上的全局位置
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final globalOffset = renderBox.localToGlobal(Offset.zero);
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // Tooltip 尺寸
    const tooltipWidth = 100.0;
    const tooltipHeight = 44.0;

    // 计算 tooltip 全局位置（相对于 heatmap 左上角）
    // 水平：默认显示在单元格右侧，溢出则显示在左侧
    var tooltipLeft =
        globalOffset.dx + _weekdayLabelWidth + 8 + (_selectedCol! * (_cellSize + _cellGap)) + _cellSize + 4;
    if (tooltipLeft + tooltipWidth > screenWidth) {
      tooltipLeft =
          globalOffset.dx + _weekdayLabelWidth + 8 + (_selectedCol! * (_cellSize + _cellGap)) - tooltipWidth - 4;
    }
    if (tooltipLeft < 0) tooltipLeft = 4;

    // 垂直：默认显示在单元格上方，溢出则显示在下方
    var tooltipTop = globalOffset.dy + _monthLabelHeight + (_selectedRow! * (_cellSize + _cellGap)) - tooltipHeight - 4;
    if (tooltipTop < globalOffset.dy) {
      tooltipTop = globalOffset.dy + _monthLabelHeight + (_selectedRow! * (_cellSize + _cellGap)) + _cellSize + 4;
    }
    if (tooltipTop + tooltipHeight > screenHeight) {
      tooltipTop = screenHeight - tooltipHeight - 8;
    }

    final overlayKey = GlobalKey<_HeatmapTooltipOverlayState>();
    _tooltipKey = overlayKey;

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => _HeatmapTooltipOverlay(
        key: overlayKey,
        left: tooltipLeft,
        top: tooltipTop,
        width: tooltipWidth,
        dateStr: dateStr,
        scoreStr: scoreStr,
        theme: theme,
        onDismiss: () => _dismissTooltip(),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  Widget _buildLegend(Color primary, Color emptyColor, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '少',
          style: TextStyle(fontSize: AppTypography.caption, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(color: emptyColor, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 2),
        Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(color: primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 2),
        Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(color: primary.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 2),
        Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(color: primary.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 2),
        Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(color: primary.withValues(alpha: 1.0), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Text(
          '多',
          style: TextStyle(fontSize: AppTypography.caption, color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 热力图悬浮提示层：补齐反向缩放淡出退场，避免点击空白处时气泡硬消失。
class _HeatmapTooltipOverlay extends StatefulWidget {
  const _HeatmapTooltipOverlay({
    super.key,
    required this.left,
    required this.top,
    required this.width,
    required this.dateStr,
    required this.scoreStr,
    required this.theme,
    required this.onDismiss,
  });

  final double left;
  final double top;
  final double width;
  final String dateStr;
  final String scoreStr;
  final ThemeData theme;
  final VoidCallback onDismiss;

  @override
  State<_HeatmapTooltipOverlay> createState() => _HeatmapTooltipOverlayState();
}

class _HeatmapTooltipOverlayState extends State<_HeatmapTooltipOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
  bool _dismissing = false;
  bool _motionInitialized = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDurations.fast);
    _curved = CurvedAnimation(parent: _controller, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionInitialized) return;
    _motionInitialized = true;
    if (AppMotion.reduce(context)) {
      _controller.value = 1.0;
    } else {
      _controller.forward();
    }
  }

  Future<void> dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    if (AppMotion.reduce(context)) {
      return;
    }
    await _controller.reverse();
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: widget.left,
          top: widget.top,
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(_curved),
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(6),
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: Container(
                    width: widget.width,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          widget.dateStr,
                          style: TextStyle(
                            fontSize: AppTypography.label,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.scoreStr,
                          style: TextStyle(fontSize: AppTypography.caption, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
