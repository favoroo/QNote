import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';

/// 统计页的日期导航条：左右逐日切换 + 点中间标签开日历，整条单行紧凑。
///
/// 从评分 tab 抽出，评分与屏幕时长共用同一套交互与样式。
/// 原先的「前天/昨天/今天」快捷按钮行挤占了近 80px 纵向空间，
/// 已换成非今天时在标签右侧出现一枚小号「今天」胶囊，一步回到今天。
class DateNavigationHeader extends StatelessWidget {
  final DateTime selectedDate;

  /// 日期变化回调，参数已归一化到当日 00:00
  final ValueChanged<DateTime> onDateChanged;

  /// 为 false 时（如正在 AI 评分）整条禁用，避免中途改日期
  final bool enabled;

  /// 允许选择的最大日期，默认今天；右箭头到达后自动禁用
  final DateTime? maxDate;

  const DateNavigationHeader({
    super.key,
    required this.selectedDate,
    required this.onDateChanged,
    this.enabled = true,
    this.maxDate,
  });

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _upperBound {
    final max = maxDate;
    if (max == null) {
      return _today;
    }
    return DateTime(max.year, max.month, max.day);
  }

  bool get _isTodaySelected {
    final today = _today;
    return selectedDate.year == today.year &&
        selectedDate.month == today.month &&
        selectedDate.day == today.day;
  }

  void _shift(int days) {
    _emit(selectedDate.add(Duration(days: days)));
  }

  void _emit(DateTime date) {
    onDateChanged(DateTime(date.year, date.month, date.day));
  }

  Future<void> _pickDate(BuildContext context) async {
    final result = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2000),
      lastDate: _upperBound,
      locale: const Locale('zh', 'CN'),
    );
    if (result != null) {
      _emit(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final canGoNext = enabled && selectedDate.isBefore(_upperBound);
    // 可选上限早于今天时不给回今天入口，否则会跳出日历允许的范围；
    // 禁用时胶囊只随整条置灰而不隐藏，避免评分开始/结束瞬间宽度跳动
    final showTodayPill = !_isTodaySelected && !_upperBound.isBefore(_today);
    final VoidCallback? previousAction = enabled ? () => _shift(-1) : null;
    final VoidCallback? nextAction = canGoNext ? () => _shift(1) : null;
    final VoidCallback? pickAction = enabled ? () => _pickDate(context) : null;
    final VoidCallback? todayAction = enabled ? () => _emit(_today) : null;

    return Opacity(
      opacity: enabled ? 1 : 0.38,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                DateNavArrow(
                  icon: Icons.chevron_left,
                  tooltip: '前一天',
                  onPressed: previousAction,
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildDateSelector(context, pickAction),
                      if (showTodayPill) DateTodayPill(onPressed: todayAction),
                    ],
                  ),
                ),
                DateNavArrow(
                  icon: Icons.chevron_right,
                  tooltip: '后一天',
                  onPressed: nextAction,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 日期标签 + 日历图标。整块可点，点开日历选日。
  ///
  /// 用 Flexible 而非 Expanded：Expanded 会把选择器撑满整行，
  /// 把「今天」胶囊推到最右侧，脱离标签。
  Widget _buildDateSelector(BuildContext context, VoidCallback? onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Flexible(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          // 窄屏（320dp）下完整日期标签可能撑不下，scaleDown 只缩不放
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  formatDayLabel(selectedDate),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 6),
                Icon(Icons.calendar_month, size: 16, color: colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

/// 日期导航条的「今天」胶囊：非今天时贴在日期标签右侧，一步回到今天。
///
/// 统计页与健康设置页共用，保证两处日期条看起来是同一个组件。
/// 放在日期选择 InkWell 之外，避免嵌套 InkWell 的手势竞争让点胶囊误开日历。
class DateTodayPill extends StatelessWidget {
  final VoidCallback? onPressed;

  const DateTodayPill({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        key: const ValueKey('date_nav_today_pill'),
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '今天',
            key: const ValueKey('date_nav_today_text'),
            maxLines: 1,
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// 日期导航条的逐日箭头。固定 40×40，让整条高度与文字无关、稳定在 48。
class DateNavArrow extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const DateNavArrow({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size(40, 40),
        iconSize: 22,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}/// 用 DateFormat 生成 M月d日 形式的短标签，供趋势图轴标签复用
String shortDayLabel(DateTime dt) => DateFormat('M月d日').format(dt);
