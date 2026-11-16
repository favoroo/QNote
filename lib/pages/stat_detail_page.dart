import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/stats_provider.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/statistics/stat_detail.dart';
import 'package:qnote_flutter/widgets/statistics/stat_record_detail_sheet.dart';

/// 统计明细二级页：区间内全部记账/饮食记录，按天分组、懒加载渲染。
class StatDetailPage extends ConsumerWidget {
  /// 明细类型：仅支持 finance / diet。
  final StatTab tab;
  final DateTime start;
  final DateTime end;

  const StatDetailPage({super.key, required this.tab, required this.start, required this.end});

  bool get _isFinance => tab == StatTab.finance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final recordsAsync = ref.watch(diaryListByDateRangeProvider((start: start, end: end)));
    final statsAsync = ref.watch(statsProvider(StatsQuery(start: start, end: end, tab: tab)));

    return Scaffold(
      appBar: AppBar(title: Text(_isFinance ? '账单明细' : '饮食明细'), centerTitle: true),
      body: statsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('加载失败：$err')),
        data: (stats) {
          final records = recordsForStatTab(recordsAsync.valueOrNull ?? const [], tab);
          final rows = _isFinance
              ? _flattenFinance((stats as FinanceStatistics).ledger)
              : _flattenDiet((stats as DietStatistics).meals);

          if (rows.isEmpty) {
            return const EmptyStateWidget(icon: Icons.receipt_long_outlined, message: '暂无明细');
          }

          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                sliver: SliverToBoxAdapter(child: _buildSummary(stats, isDark)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                sliver: SliverList.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    if (row is _DayHeaderData) {
                      return StatDayHeader(dateLabel: row.label, summary: row.summary);
                    }
                    if (row is FinanceLedgerEntry) {
                      return StatLedgerRow(entry: row, onTap: () => _open(context, records, row.recordId));
                    }
                    if (row is DietMealEntry) {
                      return StatMealRow(entry: row, onTap: () => _open(context, records, row.recordId));
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _open(BuildContext context, List<DiaryRecord> records, String recordId) {
    final index = records.indexWhere((r) => r.id == recordId);
    if (index < 0) return;
    HapticFeedback.selectionClick();
    showStatRecordSheet(context, records: records, initialIndex: index);
  }

  Widget _buildSummary(Object stats, bool isDark) {
    if (_isFinance) {
      final s = stats as FinanceStatistics;
      final hasFlow = s.totalIncome > 0 || s.totalExpense > 0;
      return StatSummaryCard(
        primaryLabel: '结余',
        primaryValue: '¥${s.balance.toStringAsFixed(0)}',
        primaryColor: s.balance >= 0 ? statIncomeColor : statExpenseColor,
        metrics: [
          StatMetric(label: '收入', value: '¥${s.totalIncome.toStringAsFixed(0)}', color: statIncomeColor),
          StatMetric(label: '支出', value: '¥${s.totalExpense.toStringAsFixed(0)}', color: statExpenseColor),
          StatMetric(label: '记录', value: '${s.totalRecords}笔'),
        ],
        child: hasFlow
            ? StatRatioBar(
                segments: [
                  StatRatioSegment(color: statIncomeColor, value: s.totalIncome),
                  StatRatioSegment(color: statExpenseColor, value: s.totalExpense),
                ],
              )
            : null,
      );
    }
    final s = stats as DietStatistics;
    final healthy = s.healthDistribution['健康'] ?? 0;
    final rate = s.totalMeals > 0 ? (healthy / s.totalMeals * 100).round() : 0;
    return StatSummaryCard(
      primaryLabel: '记录餐次',
      primaryValue: '${s.totalMeals}次',
      primaryColor: TagColors.diet,
      metrics: [
        StatMetric(label: '健康', value: '$healthy次', color: statIncomeColor),
        StatMetric(label: '健康率', value: '$rate%'),
        // 仅在至少有一餐估算了热量时展示，避免全 0 误导
        if (s.calorieMealCount > 0) StatMetric(label: '总热量', value: '${s.totalCalories.round()} kcal'),
      ],
    );
  }

  List<Object> _flattenFinance(List<FinanceLedgerEntry> ledger) {
    final rows = <Object>[];
    for (final group in groupByDay(ledger, (e) => e.time)) {
      var income = 0.0;
      var expense = 0.0;
      for (final e in group.items) {
        if (e.isIncome) {
          income += e.amount;
        } else {
          expense += e.amount;
        }
      }
      final parts = <String>[];
      if (expense > 0) parts.add('支出 ¥${formatAmount(expense)}');
      if (income > 0) parts.add('收入 ¥${formatAmount(income)}');
      rows.add(_DayHeaderData(formatDayLabel(group.date), parts.join(' · ')));
      rows.addAll(group.items);
    }
    return rows;
  }

  List<Object> _flattenDiet(List<DietMealEntry> meals) {
    final rows = <Object>[];
    for (final group in groupByDay(meals, (m) => m.time)) {
      final kcal = group.items.fold<double>(0, (sum, m) => sum + (m.calories ?? 0));
      final parts = ['共 ${group.items.length} 餐'];
      if (kcal > 0) parts.add('${kcal.round()} kcal');
      rows.add(_DayHeaderData(formatDayLabel(group.date), parts.join(' · ')));
      rows.addAll(group.items);
    }
    return rows;
  }
}

/// 扁平化列表里的日期分组头数据。
class _DayHeaderData {
  final String label;
  final String summary;

  const _DayHeaderData(this.label, this.summary);
}
