import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/utils/stats_utils.dart';

/// 统计页的日期导航头：左右逐日切换 + 日历选日 + 前天/昨天/今天快捷跳转。
///
/// 从评分 tab 抽出，评分与屏幕时长共用同一套交互与样式，
/// 避免两个页面各维护一份日期切换逻辑。
class DateNavigationHeader extends StatelessWidget {
  final DateTime selectedDate;

  /// 日期变化回调，参数已归一化到当日 00:00
  final ValueChanged<DateTime> onDateChanged;

  /// 为 false 时（如正在 AI 评分）整条禁用，避免中途改日期
  final bool enabled;

  /// 允许选择的最大日期，默认今天；右箭头到达后自动禁用
  final DateTime? maxDate;

  /// 是否显示底部快捷日期胶囊
  final bool showQuickDates;

  const DateNavigationHeader({
    super.key,
    required this.selectedDate,
    required this.onDateChanged,
    this.enabled = true,
    this.maxDate,
    this.showQuickDates = true,
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
    final theme = Theme.of(context);
    final canGoNext = enabled && selectedDate.isBefore(_upperBound);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      elevation: 0,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: enabled ? () => _shift(-1) : null,
                ),
                GestureDetector(
                  onTap: enabled ? () => _pickDate(context) : null,
                  child: Row(
                    children: [
                      Text(
                        formatDayLabel(selectedDate),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.calendar_month, size: 16, color: theme.colorScheme.primary),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: canGoNext ? () => _shift(1) : null,
                ),
              ],
            ),
            if (showQuickDates) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildQuickDateBtn('前天', _today.subtract(const Duration(days: 2)), theme),
                  _buildQuickDateBtn('昨天', _today.subtract(const Duration(days: 1)), theme),
                  _buildQuickDateBtn('今天', _today, theme),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickDateBtn(String label, DateTime btnDate, ThemeData theme) {
    final isActive = btnDate.year == selectedDate.year &&
        btnDate.month == selectedDate.month &&
        btnDate.day == selectedDate.day;

    final activeForegroundColor = isActive ? theme.colorScheme.onPrimary : theme.colorScheme.primary;
    final activeBackgroundColor = isActive ? theme.colorScheme.primary : Colors.transparent;

    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: activeForegroundColor,
        backgroundColor: activeBackgroundColor,
        disabledForegroundColor: activeForegroundColor,
        disabledBackgroundColor: activeBackgroundColor,
        side: BorderSide(
          color: isActive ? Colors.transparent : theme.colorScheme.outlineVariant,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      onPressed: enabled ? () => _emit(btnDate) : null,
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// 用 DateFormat 生成 M月d日 形式的短标签，供趋势图轴标签复用
String shortDayLabel(DateTime dt) => DateFormat('M月d日').format(dt);
