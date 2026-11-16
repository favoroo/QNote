import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fl_chart/fl_chart.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/common/sliding_pill_bar.dart';
import 'package:qnote_flutter/widgets/statistics/stat_detail.dart';
import 'package:qnote_flutter/widgets/statistics/stat_record_detail_sheet.dart';
import 'package:qnote_flutter/widgets/statistics/stat_shared.dart';

/// 记账 tab 明细预览最多展示的行数（其余交给「查看全部」二级页）。
const _ledgerPreviewMaxRows = 5;

class FinanceStatsWidget extends StatelessWidget {
  final FinanceStatistics stats;

  /// 区间内的记账记录（已按标签筛选、时间倒序），用于打开详情弹层。
  final List<DiaryRecord> records;

  /// 当前统计区间，用于把趋势图补零到完整天数。
  final DateTime startDate;
  final DateTime endDate;

  /// 「查看全部」回调，跳转到二级明细页。
  final VoidCallback onViewAll;

  const FinanceStatsWidget({
    super.key,
    required this.stats,
    required this.records,
    required this.startDate,
    required this.endDate,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        _buildSummary(context),
        if (stats.ledger.isNotEmpty) ...[const SizedBox(height: 12), _buildLedgerCard(context)],
        if (stats.expenseByType.isNotEmpty || stats.incomeByType.isNotEmpty) ...[
          const SizedBox(height: 12),
          StatCardShell(
            isDark: isDark,
            title: '分类构成',
            child: _CategoryBreakdown(
              expenseByType: stats.expenseByType,
              incomeByType: stats.incomeByType,
              isDark: isDark,
            ),
          ),
        ],
        if (stats.dailyData.isNotEmpty) ...[
          const SizedBox(height: 12),
          StatCardShell(
            isDark: isDark,
            title: '收支趋势',
            child: StatChartBox(
              height: 148,
              isEmpty: false,
              child: _FinanceTrendChart(dailyData: _fillDaily(stats.dailyData), isDark: isDark),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSummary(BuildContext context) {
    final hasFlow = stats.totalIncome > 0 || stats.totalExpense > 0;
    return StatSummaryCard(
      primaryLabel: '结余',
      primaryValue: '¥${stats.balance.toStringAsFixed(0)}',
      primaryColor: stats.balance >= 0 ? statIncomeColor : statExpenseColor,
      metrics: [
        StatMetric(label: '收入', value: '¥${stats.totalIncome.toStringAsFixed(0)}', color: statIncomeColor),
        StatMetric(label: '支出', value: '¥${stats.totalExpense.toStringAsFixed(0)}', color: statExpenseColor),
        StatMetric(label: '记录', value: '${stats.totalRecords}笔'),
      ],
      child: hasFlow
          ? StatRatioBar(
              segments: [
                StatRatioSegment(color: statIncomeColor, value: stats.totalIncome),
                StatRatioSegment(color: statExpenseColor, value: stats.totalExpense),
              ],
            )
          : null,
    );
  }

  Widget _buildLedgerCard(BuildContext context) {
    final groups = groupByDay(stats.ledger, (e) => e.time);
    final children = <Widget>[];
    var rows = 0;
    for (final group in groups) {
      if (rows >= _ledgerPreviewMaxRows) break;
      var income = 0.0;
      var expense = 0.0;
      for (final e in group.items) {
        if (e.isIncome) {
          income += e.amount;
        } else {
          expense += e.amount;
        }
      }
      children.add(StatDayHeader(dateLabel: formatDayLabel(group.date), summary: _daySummary(income, expense)));
      for (final e in group.items) {
        if (rows >= _ledgerPreviewMaxRows) break;
        children.add(StatLedgerRow(entry: e, onTap: () => _openEntry(context, e)));
        rows++;
      }
    }

    return StatCardShell(
      isDark: Theme.of(context).brightness == Brightness.dark,
      title: '明细',
      trailing: StatViewAllButton(onTap: onViewAll),
      child: Column(children: children),
    );
  }

  String _daySummary(double income, double expense) {
    final parts = <String>[];
    if (expense > 0) parts.add('支出 ¥${formatAmount(expense)}');
    if (income > 0) parts.add('收入 ¥${formatAmount(income)}');
    return parts.join(' · ');
  }

  void _openEntry(BuildContext context, FinanceLedgerEntry entry) {
    final index = records.indexWhere((r) => r.id == entry.recordId);
    if (index < 0) return;
    HapticFeedback.selectionClick();
    showStatRecordSheet(context, records: records, initialIndex: index);
  }

  /// 把只有「有记录的天」的日数据补齐到区间内每一天，避免单点/断点拉出无意义的线。
  List<FinanceDailyData> _fillDaily(List<FinanceDailyData> dailyData) {
    final byDate = {for (final d in dailyData) d.date: d};
    final result = <FinanceDailyData>[];
    var cursor = DateTime(startDate.year, startDate.month, startDate.day);
    final last = DateTime(endDate.year, endDate.month, endDate.day);
    // 区间异常或过长时兜底，避免死循环与超长列表
    var guard = 0;
    while (!cursor.isAfter(last) && guard < 400) {
      guard++;
      final m = cursor.month.toString().padLeft(2, '0');
      final d = cursor.day.toString().padLeft(2, '0');
      final key = '${cursor.year}-$m-$d';
      final hit = byDate[key];
      result.add(hit ?? FinanceDailyData(date: key, income: 0, expense: 0));
      cursor = cursor.add(const Duration(days: 1));
    }
    return result.isEmpty ? dailyData : result;
  }
}

class _FinanceTrendChart extends StatelessWidget {
  final List<FinanceDailyData> dailyData;
  final bool isDark;

  const _FinanceTrendChart({required this.dailyData, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final incomeSpots = <FlSpot>[];
    final expenseSpots = <FlSpot>[];
    for (var i = 0; i < dailyData.length; i++) {
      incomeSpots.add(FlSpot(i.toDouble(), dailyData[i].income));
      expenseSpots.add(FlSpot(i.toDouble(), dailyData[i].expense));
    }
    final step = (dailyData.length / 6).ceil().clamp(1, 999);

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(color: AppPalette.chartGrid(isDark), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= dailyData.length || idx % step != 0) return const SizedBox.shrink();
                final parts = dailyData[idx].date.split('-');
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${parts[1]}/${parts[2]}',
                    style: const TextStyle(fontSize: AppTypography.caption, color: AppPalette.textMuted),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 38,
              getTitlesWidget: (value, meta) => Text(
                '¥${value.toInt()}',
                style: const TextStyle(fontSize: AppTypography.micro, color: AppPalette.textMuted),
              ),
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: incomeSpots,
            isCurved: true,
            color: statIncomeColor,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
          LineChartBarData(
            spots: expenseSpots,
            isCurved: true,
            color: statExpenseColor,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) {
              return spots.map((spot) {
                final isIncome = spot.bar.color == statIncomeColor;
                return LineTooltipItem(
                  '${isIncome ? "收入" : "支出"}: ¥${spot.y.toStringAsFixed(0)}',
                  TextStyle(color: isIncome ? statIncomeColor : statExpenseColor, fontSize: 12),
                );
              }).toList();
            },
          ),
        ),
      ),
      duration: AppMotion.duration(context, AppDurations.medium),
      curve: AppCurves.emphasized,
    );
  }
}

/// 支出 / 收入分类构成：可切换，紧凑排行（图标 + 名称 + 占比条 + 金额）。
class _CategoryBreakdown extends StatefulWidget {
  final Map<String, double> expenseByType;
  final Map<String, double> incomeByType;
  final bool isDark;

  const _CategoryBreakdown({required this.expenseByType, required this.incomeByType, required this.isDark});

  @override
  State<_CategoryBreakdown> createState() => _CategoryBreakdownState();
}

class _CategoryBreakdownState extends State<_CategoryBreakdown> {
  bool _showIncome = false;

  @override
  Widget build(BuildContext context) {
    final hasExpense = widget.expenseByType.isNotEmpty;
    final hasIncome = widget.incomeByType.isNotEmpty;
    // 只有支出一侧时无需切换
    final effectiveIncome = hasIncome && (!hasExpense || _showIncome);
    final data = (effectiveIncome ? widget.incomeByType : widget.expenseByType).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final shown = data.take(5).toList();
    final maxVal = shown.fold<double>(0, (max, e) => e.value > max ? e.value : max);
    final color = effectiveIncome ? statIncomeColor : statExpenseColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasExpense && hasIncome) ...[_toggle(context, widget.isDark), const SizedBox(height: 12)],
        AppMotion.switcher(
          context: context,
          baseDuration: AppDurations.fast,
          scale: false,
          child: Column(
            key: ValueKey<bool>(effectiveIncome),
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _CategoryRow(
                  category: shown[i].key,
                  amount: shown[i].value,
                  pct: maxVal > 0 ? shown[i].value / maxVal : 0,
                  color: color,
                  isIncome: effectiveIncome,
                  isDark: widget.isDark,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _toggle(BuildContext context, bool isDark) {
    return SlidingPillBar(
      labels: const ['支出', '收入'],
      selectedIndex: _showIncome ? 1 : 0,
      onSelected: (index) => setState(() => _showIncome = index == 1),
      height: 32,
      padding: 2,
      fixedSegmentWidth: 54,
      outerRadius: 10,
      pillRadius: 8,
      trackColor: AppPalette.chipBackground(isDark),
      pillColor: Theme.of(context).colorScheme.surface,
      selectedColorOf: (index) => index == 1 ? statIncomeColor : statExpenseColor,
      unselectedColor: AppPalette.textMuted,
      fontSize: AppTypography.bodySmall,
      showPillShadow: true,
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String category;
  final double amount;
  final double pct;
  final Color color;
  final bool isIncome;
  final bool isDark;

  const _CategoryRow({
    required this.category,
    required this.amount,
    required this.pct,
    required this.color,
    required this.isIncome,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(ledgerCategoryIcon(category, isIncome: isIncome), size: 15, color: color),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          child: Text(
            category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppTypography.bodySmall, color: AppPalette.textSecondary(isDark)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StatProgressBar(isDark: isDark, value: pct, color: color, minHeight: 8),
        ),
        const SizedBox(width: 8),
        Text(
          '¥${formatAmount(amount)}',
          style: TextStyle(
            fontSize: AppTypography.label,
            fontWeight: FontWeight.bold,
            color: AppPalette.textPrimary(isDark),
          ),
        ),
      ],
    );
  }
}
