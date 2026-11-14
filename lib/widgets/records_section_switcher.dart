import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/shell_branch_container.dart';

/// 笔记 / 待办合并后的 AppBar 分段切换胶囊。
///
/// 两页仍各自保留独立的 shell 分支与页面状态，这里只负责跳转分支：
/// 切换不会重建目标页面，底部「记录」入口的选中态也由当前分支索引决定。
///
/// 胶囊高亮是**单一滑动指示器**：它在 [RecordsSectionScope] 广播的位置动画上移动，
/// 笔记页与待办页在交叉溶解期间读到的是同一条轨迹，因此看不到「两块胶囊互相淡入」。
/// 两段宽度固定相等，整条胶囊的总宽恒定 —— AppBar 居中标题的两端不会跟着抖。
class RecordsSectionSwitcher extends StatelessWidget {
  /// 单个分段宽度（两个标签都是两字，等宽即可让指示器按格滑动）。
  static const double _segmentWidth = 56;

  /// 胶囊内容高度。
  static const double _segmentHeight = 30;

  /// 外框内边距。
  static const double _outerPadding = 3;

  /// 当前页所属分段
  final RecordsSection active;

  const RecordsSectionSwitcher({super.key, required this.active});

  double get _activeValue => active == RecordsSection.todo ? 1.0 : 0.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sharedPosition = RecordsSectionScope.maybeOf(context);
    final fallbackDuration = AppMotion.duration(context, AppDurations.fast);

    return Container(
      padding: const EdgeInsets.all(_outerPadding),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(18),
      ),
      // 有共享位置动画时（处于 shell 分支容器内）跟随它滑动；
      // 否则（如 widget 测试里单独渲染本页）回退到本地隐式动画，保证仍有滑动效果。
      child: sharedPosition != null
          ? AnimatedBuilder(
              animation: sharedPosition,
              builder: (context, _) => _buildTrack(context, theme, colorScheme, sharedPosition.value),
            )
          : TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: _activeValue, end: _activeValue),
              duration: fallbackDuration,
              curve: AppCurves.standard,
              builder: (context, value, _) => _buildTrack(context, theme, colorScheme, value),
            ),
    );
  }

  /// [position] 为 0~1 的连续位置：0 表示指示器在「笔记」，1 表示在「待办」。
  Widget _buildTrack(BuildContext context, ThemeData theme, ColorScheme colorScheme, double position) {
    return SizedBox(
      height: _segmentHeight,
      width: _segmentWidth * 2,
      child: Stack(
        children: [
          Positioned(
            left: _segmentWidth * position,
            top: 0,
            bottom: 0,
            width: _segmentWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(_segmentHeight / 2),
                // 同色系背景（主题色背景）下实心指示块与轨道同色，补一圈细描边交代边界
                border: theme.accentNeedsOutline ? Border.all(color: colorScheme.outlineVariant) : null,
              ),
            ),
          ),
          Row(
            children: [
              _buildSegment(context, theme, colorScheme, '笔记', 0, position, RecordsSection.notes, '/notes'),
              _buildSegment(context, theme, colorScheme, '待办', 1, position, RecordsSection.todo, '/todo'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSegment(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    String label,
    int index,
    double position,
    RecordsSection section,
    String location,
  ) {
    // 指示器离该段越近，文字越接近「选中」配色；用连续插值避免字重/颜色瞬变。
    final onStrength = (1 - (position - index).abs()).clamp(0.0, 1.0);
    final textColor = Color.lerp(colorScheme.onSurfaceVariant, colorScheme.onPrimary, onStrength)!;
    final fontWeight = FontWeight.lerp(FontWeight.w600, FontWeight.w700, onStrength)!;

    return Semantics(
      button: true,
      selected: section == active,
      child: PressableScale(
        pressedScale: 0.96,
        behavior: HitTestBehavior.opaque,
        onTap: () => _switchTo(context, section, location),
        child: SizedBox(
          width: _segmentWidth,
          height: _segmentHeight,
          child: Center(
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: fontWeight, color: textColor),
            ),
          ),
        ),
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
