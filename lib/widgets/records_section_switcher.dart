import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';

/// 笔记 / 待办合并后的 AppBar 分段切换胶囊。
///
/// 两页仍各自保留独立的 shell 分支与页面状态，这里只负责跳转分支：
/// 切换不会重建目标页面，底部「记录」入口的选中态也由当前分支索引决定。
class RecordsSectionSwitcher extends StatelessWidget {
  /// 当前页所属分段
  final RecordsSection active;

  const RecordsSectionSwitcher({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SegmentChip(
            label: '笔记',
            selected: active == RecordsSection.notes,
            onTap: () => _switchTo(context, RecordsSection.notes, '/notes'),
          ),
          _SegmentChip(
            label: '待办',
            selected: active == RecordsSection.todo,
            onTap: () => _switchTo(context, RecordsSection.todo, '/todo'),
          ),
        ],
      ),
    );
  }

  void _switchTo(BuildContext context, RecordsSection section, String location) {
    if (section == active) return;
    HapticFeedback.selectionClick();
    // 走分支跳转而不是重建页面：目标页的滚动位置、分类与列表状态都保留
    context.go(location);
  }
}

class _SegmentChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppDurations.fast),
          curve: AppCurves.standard,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
