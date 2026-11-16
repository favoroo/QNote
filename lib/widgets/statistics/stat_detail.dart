import 'package:flutter/material.dart';

import 'package:fl_chart/fl_chart.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_palette.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/theme/tag_colors.dart';
import 'package:qnote_flutter/core/utils/stats_utils.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';
import 'package:qnote_flutter/widgets/statistics/stat_shared.dart';

/// 统计明细通用配色：收入（绿）/ 支出（红），与时间线卡片口径一致。
const Color statIncomeColor = Color(0xFF10B981);
const Color statExpenseColor = Color(0xFFEF4444);

/// 饮食健康评价配色，供明细行与占比条复用。
Color dietHealthColor(String key) {
  switch (key) {
    case '健康':
      return const Color(0xFF10B981);
    case '一般':
      return const Color(0xFFF59E0B);
    case '不健康':
      return const Color(0xFFEF4444);
    case '过于放纵':
      return const Color(0xFF991B1B);
    default:
      return const Color(0xFF6B7280);
  }
}

/// 记账分类图标：常见分类给专属图标，未知分类回退到小票图标。
IconData ledgerCategoryIcon(String category, {required bool isIncome}) {
  switch (category) {
    case '饮食':
      return Icons.restaurant;
    case '交通':
      return Icons.directions_bus_outlined;
    case '购物':
      return Icons.shopping_bag_outlined;
    case '娱乐':
      return Icons.sports_esports_outlined;
    case '居家':
      return Icons.home_outlined;
    case '人情':
      return Icons.card_giftcard;
    case '医疗':
      return Icons.local_hospital_outlined;
    case '房租':
      return Icons.vpn_key_outlined;
    case '数码':
      return Icons.devices_outlined;
    case '教育':
      return Icons.school_outlined;
    case '服饰':
      return Icons.checkroom_outlined;
    case '美容':
      return Icons.face_retouching_natural;
    case '宠物':
      return Icons.pets;
    case '工资':
      return Icons.payments_outlined;
    case '奖金':
      return Icons.emoji_events_outlined;
    case '红包':
      return Icons.redeem_outlined;
    case '兼职':
      return Icons.work_outline;
    case '理财':
      return Icons.trending_up;
    case '报销':
      return Icons.receipt_long_outlined;
    default:
      return isIncome ? Icons.attach_money : Icons.receipt_long_outlined;
  }
}

/// 按天分组后的明细组：同一天的所有条目。
class StatDayGroup<T> {
  /// 日期键 yyyy-MM-dd。
  final String dateKey;

  /// 归属日期（当天 0 点）。
  final DateTime date;

  /// 当天明细，保持传入顺序。
  final List<T> items;

  StatDayGroup({required this.dateKey, required this.date, required this.items});
}

String _dateKey(DateTime t) {
  final m = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  return '${t.year}-$m-$d';
}

/// 把明细按天分组，天倒序（最新在前）；天内顺序沿用传入顺序。
///
/// 纯函数，便于单测；记账与饮食明细共用同一分组口径。
List<StatDayGroup<T>> groupByDay<T>(List<T> items, DateTime Function(T) timeOf) {
  final buckets = <String, List<T>>{};
  final dates = <String, DateTime>{};
  for (final item in items) {
    final t = timeOf(item);
    final key = _dateKey(t);
    buckets.putIfAbsent(key, () => <T>[]).add(item);
    dates.putIfAbsent(key, () => DateTime(t.year, t.month, t.day));
  }
  final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final k in keys) StatDayGroup(dateKey: k, date: dates[k]!, items: buckets[k]!)];
}

/// 金额展示：支出加「-」前缀，收入加「+」前缀，保留到分但整数不带小数。
String formatAmount(double value) {
  final abs = value.abs();
  final text = abs == abs.roundToDouble() ? abs.toStringAsFixed(0) : abs.toStringAsFixed(2);
  return text;
}

/// 紧凑汇总卡：左侧突出一个主指标，右侧竖排若干次要指标，下方可挂一条占比条。
class StatSummaryCard extends StatelessWidget {
  /// 主指标标题。
  final String primaryLabel;

  /// 主指标数值（含单位前缀）。
  final String primaryValue;

  /// 主指标颜色。
  final Color primaryColor;

  /// 次要指标。
  final List<StatMetric> metrics;

  /// 主指标下方的附加内容（如占比条）。
  final Widget? child;

  const StatSummaryCard({
    super.key,
    required this.primaryLabel,
    required this.primaryValue,
    required this.primaryColor,
    this.metrics = const [],
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return StatCardContainer(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      primaryLabel,
                      style: const TextStyle(
                        fontSize: AppTypography.label,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.textMuted,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      primaryValue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: primaryColor,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (metrics.isNotEmpty) ...[
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < metrics.length; i++) ...[
                      if (i > 0) const SizedBox(height: 5),
                      _buildMetric(metrics[i], isDark),
                    ],
                  ],
                ),
              ],
            ],
          ),
          if (child != null) ...[const SizedBox(height: 12), child!],
        ],
      ),
    );
  }

  Widget _buildMetric(StatMetric metric, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          metric.label,
          style: const TextStyle(fontSize: AppTypography.label, color: AppPalette.textMuted),
        ),
        const SizedBox(width: 6),
        Text(
          metric.value,
          style: TextStyle(
            fontSize: AppTypography.body,
            fontWeight: FontWeight.bold,
            color: metric.color ?? AppPalette.textPrimary(isDark),
          ),
        ),
      ],
    );
  }
}

/// 汇总卡里的单个次要指标。
class StatMetric {
  final String label;
  final String value;
  final Color? color;

  const StatMetric({required this.label, required this.value, this.color});
}

/// 明细列表的日期分组头：左侧日期标签（今天/昨天/…），右侧当日合计。
class StatDayHeader extends StatelessWidget {
  final String dateLabel;
  final String summary;

  const StatDayHeader({super.key, required this.dateLabel, required this.summary});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Row(
        children: [
          Text(
            dateLabel,
            style: TextStyle(
              fontSize: AppTypography.bodySmall,
              fontWeight: FontWeight.bold,
              color: AppPalette.textPrimary(isDark),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(height: 1, thickness: 0.5, color: AppPalette.border(isDark))),
          const SizedBox(width: 8),
          Text(
            summary,
            style: const TextStyle(
              fontSize: AppTypography.label,
              fontWeight: FontWeight.w600,
              color: AppPalette.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一笔记账的紧凑明细行。
class StatLedgerRow extends StatelessWidget {
  final FinanceLedgerEntry entry;
  final VoidCallback? onTap;

  const StatLedgerRow({super.key, required this.entry, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = entry.isIncome ? statIncomeColor : statExpenseColor;
    final note = entry.note;

    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _IconCircle(
              icon: ledgerCategoryIcon(entry.category, isIncome: entry.isIncome),
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypography.body,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.textPrimary(isDark),
                    ),
                  ),
                  if (note != null)
                    Text(
                      note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: AppTypography.label, color: AppPalette.textMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${entry.isIncome ? '+' : '-'}¥${formatAmount(entry.amount)}',
              style: TextStyle(fontSize: AppTypography.bodyLarge, fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条饮食的紧凑明细行。
class StatMealRow extends StatelessWidget {
  final DietMealEntry entry;
  final VoidCallback? onTap;

  const StatMealRow({super.key, required this.entry, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final healthColor = dietHealthColor(entry.health);
    final title = entry.item ?? entry.note ?? '饮食记录';
    final subtitle = entry.item != null ? entry.note : null;
    final time = '${entry.time.hour.toString().padLeft(2, '0')}:${entry.time.minute.toString().padLeft(2, '0')}';

    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const _IconCircle(icon: Icons.restaurant, color: TagColors.diet),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypography.body,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.textPrimary(isDark),
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: AppTypography.label, color: AppPalette.textMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (entry.calories != null && entry.calories! > 0) ...[
              Text(
                '${entry.calories!.round()} kcal',
                style: TextStyle(
                  fontSize: AppTypography.label,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textSecondary(isDark),
                ),
              ),
              const SizedBox(width: 8),
            ],
            _RatingChip(label: entry.health, color: healthColor),
            const SizedBox(width: 8),
            Text(
              time,
              style: const TextStyle(fontSize: AppTypography.label, color: AppPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 明细行左侧的圆形分类图标。
class _IconCircle extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _IconCircle({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// 健康评价小胶囊。
class _RatingChip extends StatelessWidget {
  final String label;
  final Color color;

  const _RatingChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = AppContrast.inkOnTint(color, Theme.of(context).colorScheme.surface, 0.12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: isDark ? Border.all(color: color.withValues(alpha: 0.3), width: 0.5) : null,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: AppTypography.caption, fontWeight: FontWeight.w600, color: ink),
      ),
    );
  }
}

/// 明细卡标题栏右侧的「查看全部 ›」入口。
class StatViewAllButton extends StatelessWidget {
  final VoidCallback onTap;

  const StatViewAllButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PressableScale(
      onTap: onTap,
      pressedScale: 0.92,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '查看全部',
            style: TextStyle(fontSize: AppTypography.bodySmall, fontWeight: FontWeight.w600, color: theme.accentInk),
          ),
          Icon(Icons.chevron_right_rounded, size: 18, color: theme.accentInk),
        ],
      ),
    );
  }
}

/// 占比条的单个分段。
class StatRatioSegment {
  final Color color;
  final double value;

  const StatRatioSegment({required this.color, required this.value});
}

/// 分段占比条：宽度按各段数值等比分配，总值为 0 时显示空轨道。
class StatRatioBar extends StatelessWidget {
  final List<StatRatioSegment> segments;
  final double height;

  const StatRatioBar({super.key, required this.segments, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
    final visible = segments.where((s) => s.value > 0).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: total <= 0
            ? ColoredBox(color: AppPalette.progressTrack(isDark))
            : Row(
                // 关键：ColoredBox 没有子节点时默认高度为 0，
                // 必须让 Row 拉伸子项到轨道高度，否则整条占比条不可见。
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: (visible[i].value / total * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: visible[i].color),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// 占比条图例：一排「色点 + 名称 + 数量」。
class StatRatioLegend extends StatelessWidget {
  final List<(Color, String, int)> items;

  const StatRatioLegend({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final item in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: item.$1, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                '${item.$2} ${item.$3}',
                style: TextStyle(
                  fontSize: AppTypography.label,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textSecondary(isDark),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// 环形图的单个分段。
class StatDonutSegment {
  final String label;
  final int value;
  final Color color;

  const StatDonutSegment({required this.label, required this.value, required this.color});
}

/// 紧凑环形图（固定尺寸，中心可放一行摘要），配合 [StatDonutLegend] 使用。
class StatDonutChart extends StatelessWidget {
  final List<StatDonutSegment> segments;
  final double size;
  final String? centerValue;
  final String? centerLabel;

  const StatDonutChart({super.key, required this.segments, this.size = 116, this.centerValue, this.centerLabel});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visible = segments.where((s) => s.value > 0).toList();
    const centerSpace = 30.0;
    final ringRadius = size / 2 - centerSpace - 4;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (visible.isEmpty)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppPalette.progressTrack(isDark), width: ringRadius),
              ),
            )
          else
            PieChart(
              PieChartData(
                sections: [
                  for (final s in visible)
                    PieChartSectionData(
                      value: s.value.toDouble(),
                      color: s.color,
                      radius: ringRadius,
                      showTitle: false,
                    ),
                ],
                sectionsSpace: 2,
                centerSpaceRadius: centerSpace,
                startDegreeOffset: -90,
              ),
              duration: AppMotion.duration(context, AppDurations.medium),
              curve: AppCurves.emphasized,
            ),
          if (centerValue != null)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  centerValue!,
                  style: TextStyle(
                    fontSize: AppTypography.subtitle,
                    fontWeight: FontWeight.bold,
                    color: AppPalette.textPrimary(isDark),
                  ),
                ),
                if (centerLabel != null)
                  Text(
                    centerLabel!,
                    style: const TextStyle(fontSize: AppTypography.caption, color: AppPalette.textMuted),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 环形图右侧的竖向图例：色点 + 名称 + 次数。
class StatDonutLegend extends StatelessWidget {
  final List<StatDonutSegment> segments;

  const StatDonutLegend({super.key, required this.segments});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 9),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: segments[i].color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  segments[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppTypography.bodySmall, color: AppPalette.textSecondary(isDark)),
                ),
              ),
              Text(
                '${segments[i].value}次',
                style: TextStyle(
                  fontSize: AppTypography.bodySmall,
                  fontWeight: FontWeight.bold,
                  color: AppPalette.textPrimary(isDark),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
