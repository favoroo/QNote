import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';

/// 通用单胶囊滑动分段控制器。
///
/// 参考 [TimeRangeSelector] 与 [RecordsSectionSwitcher] 的设计语言：
/// 单个连续平移胶囊 + 文字颜色/字重连续插值 + [PressableScale] 按压反馈。
/// 适用于 2~4 项紧凑横向互斥切换（如「显示大小」「支出/收入」等）。
class SlidingPillBar extends StatelessWidget {
  const SlidingPillBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.height = 40.0,
    this.padding = 4.0,
    this.fixedSegmentWidth,
    this.outerRadius,
    this.pillRadius,
    this.trackColor,
    this.pillColor,
    this.selectedColorOf,
    this.unselectedColor,
    this.fontSize = 13.0,
    this.showPillShadow = false,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final double height;
  final double padding;

  /// 为 null 时等分父容器宽度；非 null 时按固定单格宽度收缩包裹。
  final double? fixedSegmentWidth;

  final double? outerRadius;
  final double? pillRadius;
  final Color? trackColor;
  final Color? pillColor;
  final Color Function(int index)? selectedColorOf;
  final Color? unselectedColor;
  final double fontSize;
  final bool showPillShadow;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final safeIndex = selectedIndex.clamp(0, labels.length - 1);
    final innerHeight = height - padding * 2;
    final effectiveOuterRadius = outerRadius ?? (height / 2);
    final effectivePillRadius = pillRadius ?? (innerHeight / 2);
    final effectiveTrackColor = trackColor ?? colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
    final effectivePillColor = pillColor ?? colorScheme.primary;
    final effectiveUnselected = unselectedColor ?? colorScheme.onSurfaceVariant;
    final needsOutline = effectivePillColor == colorScheme.primary && theme.accentNeedsOutline;

    Widget buildWithWidth(double segmentWidth) {
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(end: safeIndex.toDouble()),
        duration: AppMotion.duration(context, AppDurations.fast),
        curve: AppCurves.emphasized,
        builder: (context, position, _) {
          return SizedBox(
            height: innerHeight,
            width: segmentWidth * labels.length,
            child: Stack(
              children: [
                Positioned(
                  left: segmentWidth * position,
                  top: 0,
                  bottom: 0,
                  width: segmentWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: effectivePillColor,
                      borderRadius: BorderRadius.circular(effectivePillRadius),
                      border: needsOutline ? Border.all(color: colorScheme.outlineVariant) : null,
                      boxShadow: showPillShadow
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      _buildSegment(
                        context: context,
                        theme: theme,
                        colorScheme: colorScheme,
                        label: labels[i],
                        index: i,
                        width: segmentWidth,
                        height: innerHeight,
                        position: position,
                        isSelected: i == safeIndex,
                        selectedColor: selectedColorOf?.call(i) ?? colorScheme.onPrimary,
                        unselectedColor: effectiveUnselected,
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    }

    return Container(
      height: height,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(color: effectiveTrackColor, borderRadius: BorderRadius.circular(effectiveOuterRadius)),
      child: fixedSegmentWidth != null
          ? buildWithWidth(fixedSegmentWidth!)
          : LayoutBuilder(
              builder: (context, constraints) {
                final segmentWidth = constraints.maxWidth.isFinite ? constraints.maxWidth / labels.length : 72.0;
                return buildWithWidth(segmentWidth);
              },
            ),
    );
  }

  Widget _buildSegment({
    required BuildContext context,
    required ThemeData theme,
    required ColorScheme colorScheme,
    required String label,
    required int index,
    required double width,
    required double height,
    required double position,
    required bool isSelected,
    required Color selectedColor,
    required Color unselectedColor,
  }) {
    final onStrength = (1 - (position - index).abs()).clamp(0.0, 1.0);
    final textColor = Color.lerp(unselectedColor, selectedColor, onStrength)!;
    final fontWeight = FontWeight.lerp(FontWeight.w600, FontWeight.w700, onStrength)!;

    return Semantics(
      button: true,
      selected: isSelected,
      child: PressableScale(
        pressedScale: 0.96,
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (isSelected) return;
          HapticFeedback.selectionClick();
          onSelected(index);
        },
        child: SizedBox(
          width: width,
          height: height,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: fontSize,
                  fontWeight: fontWeight,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
