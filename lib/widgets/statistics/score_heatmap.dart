import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
  int? _selectedRow;
  int? _selectedCol;

  Color _getCellColor(Color primary, int score) {
    if (score >= 76) return primary.withValues(alpha: 1.0);
    if (score >= 51) return primary.withValues(alpha: 0.6);
    if (score >= 26) return primary.withValues(alpha: 0.35);
    return primary.withValues(alpha: 0.15);
  }

  void _dismissTooltip() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (_selectedRow != null || _selectedCol != null) {
      setState(() {
        _selectedRow = null;
        _selectedCol = null;
      });
    }
  }

  @override
  void dispose() {
    _dismissTooltip();
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
          child: Text('暂无评分数据', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
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
        final weekdayLabels = [
          (1, '一'),
          (3, '三'),
          (5, '五'),
        ];

        // 计算网格实际宽度
        final gridWidth = weekCount * _cellSize + (weekCount - 1) * _cellGap;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: _monthLabelHeight),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 星期标签列
                SizedBox(
                  width: _weekdayLabelWidth,
                  child: Column(
                    children: List.generate(7, (row) {
                      final weekday = row + 1;
                      final labelEntry = weekdayLabels.firstWhere(
                        (e) => e.$1 == weekday,
                        orElse: () => (weekday, ''),
                      );
                      return SizedBox(
                        height: _cellSize + _cellGap,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            labelEntry.$2,
                            style: TextStyle(
                              fontSize: 9,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }),
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
                            style: TextStyle(
                              fontSize: 9,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        );
                      }),
                      // 用 Column + Row 绘制网格，确保 7 行 × N 列
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(7, (row) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var col = 0; col < weekCount; col++) ...[
                                if (col > 0) SizedBox(width: _cellGap),
                                _buildCell(weeks[col], row, col, scoreMap, primary, emptyColor, theme),
                              ],
                            ],
                          );
                        }),
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
      return SizedBox(width: _cellSize, height: _cellSize);
    }

    final day = week[row];
    final key = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final score = scoreMap[key];
    final color = score != null ? _getCellColor(primary, score) : emptyColor;
    final isSelected = _selectedRow == row && _selectedCol == col;

    return GestureDetector(
      onTap: () {
        _dismissTooltip();
        setState(() {
          _selectedRow = row;
          _selectedCol = col;
        });
        _showOverlayTooltip(day, score, theme);
      },
      child: Container(
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
    var tooltipLeft = globalOffset.dx + _weekdayLabelWidth + 8 + (_selectedCol! * (_cellSize + _cellGap)) + _cellSize + 4;
    if (tooltipLeft + tooltipWidth > screenWidth) {
      tooltipLeft = globalOffset.dx + _weekdayLabelWidth + 8 + (_selectedCol! * (_cellSize + _cellGap)) - tooltipWidth - 4;
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

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          // ModalBarrier：点击任意位置关闭 tooltip
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissTooltip,
              child: Container(color: Colors.transparent),
            ),
          ),
          // Tooltip
          Positioned(
            left: tooltipLeft,
            top: tooltipTop,
            child: IgnorePointer(
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(6),
                color: theme.colorScheme.surfaceContainerHigh,
                child: Container(
                  width: tooltipWidth,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        scoreStr,
                        style: TextStyle(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  Widget _buildLegend(Color primary, Color emptyColor, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text('少', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 6),
        Container(width: _cellSize, height: _cellSize, decoration: BoxDecoration(color: emptyColor, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 2),
        Container(width: _cellSize, height: _cellSize, decoration: BoxDecoration(color: primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 2),
        Container(width: _cellSize, height: _cellSize, decoration: BoxDecoration(color: primary.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 2),
        Container(width: _cellSize, height: _cellSize, decoration: BoxDecoration(color: primary.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 2),
        Container(width: _cellSize, height: _cellSize, decoration: BoxDecoration(color: primary.withValues(alpha: 1.0), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text('多', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
