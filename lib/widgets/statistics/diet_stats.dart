import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/statistics/stat_detail.dart';
import 'package:qnote_flutter/widgets/statistics/stat_record_detail_sheet.dart';
import 'package:qnote_flutter/widgets/statistics/stat_shared.dart';

/// 健康评价固定展示顺序。
const _healthOrder = ['健康', '一般', '不健康', '过于放纵'];

/// 饮食 tab 明细预览最多展示的行数（其余交给「查看全部」二级页）。
const _mealPreviewMaxRows = 5;

class DietStatsWidget extends StatelessWidget {
  final DietStatistics stats;

  /// 区间内的饮食记录（已按标签筛选、时间倒序），用于打开详情弹层。
  final List<DiaryRecord> records;

  /// 「查看全部」回调，跳转到二级明细页。
  final VoidCallback onViewAll;

  const DietStatsWidget({super.key, required this.stats, required this.records, required this.onViewAll});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final healthy = stats.healthDistribution['健康'] ?? 0;
    final rate = stats.totalMeals > 0 ? (healthy / stats.totalMeals * 100).round() : 0;
    final healthSegments = [
      for (final key in _healthOrder)
        if ((stats.healthDistribution[key] ?? 0) > 0)
          StatDonutSegment(label: key, value: stats.healthDistribution[key] ?? 0, color: dietHealthColor(key)),
    ];
    final foodData = stats.typeDistribution.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: [
        StatSummaryCard(
          primaryLabel: '记录餐次',
          primaryValue: '${stats.totalMeals}次',
          primaryColor: TagColors.diet,
          metrics: [
            StatMetric(label: '健康', value: '$healthy次', color: const Color(0xFF10B981)),
            StatMetric(label: '健康率', value: '$rate%'),
            // 仅在至少有一餐估算了热量时展示，避免全 0 误导
            if (stats.calorieMealCount > 0) StatMetric(label: '总热量', value: '${stats.totalCalories.round()} kcal'),
          ],
        ),
        if (stats.meals.isNotEmpty) ...[const SizedBox(height: 12), _buildMealCard(context)],
        if (foodData.isNotEmpty) ...[
          const SizedBox(height: 12),
          StatCardShell(
            isDark: isDark,
            title: '吃了什么',
            child: _FoodRanking(data: foodData.take(6).toList(), isDark: isDark),
          ),
        ],
        if (healthSegments.isNotEmpty) ...[
          const SizedBox(height: 12),
          StatCardShell(
            isDark: isDark,
            title: '健康评价',
            child: Row(
              children: [
                StatDonutChart(segments: healthSegments, centerValue: '${stats.totalMeals}', centerLabel: '餐'),
                const SizedBox(width: 20),
                Expanded(child: StatDonutLegend(segments: healthSegments)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMealCard(BuildContext context) {
    final groups = groupByDay(stats.meals, (m) => m.time);
    final children = <Widget>[];
    var rows = 0;
    for (final group in groups) {
      if (rows >= _mealPreviewMaxRows) break;
      children.add(StatDayHeader(dateLabel: formatDayLabel(group.date), summary: '共 ${group.items.length} 餐'));
      for (final m in group.items) {
        if (rows >= _mealPreviewMaxRows) break;
        children.add(StatMealRow(entry: m, onTap: () => _openEntry(context, m)));
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

  void _openEntry(BuildContext context, DietMealEntry entry) {
    final index = records.indexWhere((r) => r.id == entry.recordId);
    if (index < 0) return;
    HapticFeedback.selectionClick();
    showStatRecordSheet(context, records: records, initialIndex: index);
  }
}

/// 吃了什么排行：名称 + 次数 + 占比条。
class _FoodRanking extends StatelessWidget {
  final List<MapEntry<String, int>> data;
  final bool isDark;

  const _FoodRanking({required this.data, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final maxVal = data.fold<int>(0, (max, e) => e.value > max ? e.value : max);

    return Column(
      children: data.asMap().entries.map((entry) {
        final idx = entry.key;
        final item = entry.value;
        return Padding(
          padding: EdgeInsets.only(bottom: idx == data.length - 1 ? 0 : 10),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  item.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppTypography.bodySmall, color: AppPalette.textSecondary(isDark)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatProgressBar(
                  isDark: isDark,
                  value: maxVal > 0 ? item.value / maxVal : 0,
                  color: TagColors.diet,
                  minHeight: 8,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 34,
                child: Text(
                  '${item.value}次',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: AppTypography.label,
                    fontWeight: FontWeight.bold,
                    color: AppPalette.textPrimary(isDark),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
