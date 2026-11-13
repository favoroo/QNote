import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';

enum TimeRangeType { week, month, year }

/// 周/月/年时间跨度分段开关。
///
/// 采用与记录分段一致的单胶囊滑动指示器 + 连续文字配色插值，
/// 配合按压缩放与轻触反馈，消除多块各自变色时的孤立感。
class TimeRangeSelector extends StatelessWidget {
  final TimeRangeType selectedRange;
  final ValueChanged<TimeRangeType> onRangeChanged;

  const TimeRangeSelector({super.key, required this.selectedRange, required this.onRangeChanged});

  static const double _segmentWidth = 60.0;
  static const double _segmentHeight = 36.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const ranges = TimeRangeType.values;
    final targetPosition = selectedRange.index.toDouble();

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: targetPosition),
        duration: AppMotion.duration(context, AppDurations.fast),
        curve: AppCurves.emphasized,
        builder: (context, position, _) {
          return SizedBox(
            height: _segmentHeight,
            width: _segmentWidth * ranges.length,
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
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (int i = 0; i < ranges.length; i++) _buildSegment(context, colorScheme, ranges[i], i, position),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSegment(BuildContext context, ColorScheme colorScheme, TimeRangeType range, int index, double position) {
    final isSelected = range == selectedRange;
    final onStrength = (1 - (position - index).abs()).clamp(0.0, 1.0);
    final textColor = Color.lerp(
      colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      colorScheme.onPrimary,
      onStrength,
    )!;
    final fontWeight = FontWeight.lerp(FontWeight.w600, FontWeight.w700, onStrength)!;

    return Semantics(
      button: true,
      selected: isSelected,
      child: PressableScale(
        pressedScale: 0.95,
        onTap: () {
          if (isSelected) return;
          HapticFeedback.selectionClick();
          onRangeChanged(range);
        },
        child: SizedBox(
          width: _segmentWidth,
          height: _segmentHeight,
          child: Center(
            child: Text(
              _label(range),
              style: TextStyle(color: textColor, fontSize: 14, fontWeight: fontWeight),
            ),
          ),
        ),
      ),
    );
  }

  String _label(TimeRangeType range) {
    switch (range) {
      case TimeRangeType.week:
        return '周';
      case TimeRangeType.month:
        return '月';
      case TimeRangeType.year:
        return '年';
    }
  }
}
