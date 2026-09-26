import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/utils/diary_progress.dart';
import 'package:qnote_flutter/providers/diary_progress_provider.dart';

/// 发起「到统计页看记录坚持」的定位，置意图后跳转。
///
/// 圆环与庆祝胶囊的「看看统计」共用，避免两个入口落到不同位置。
void goStreakFocus(BuildContext context, WidgetRef ref) {
  ref.read(streakFocusProvider.notifier).state = DateTime.now();
  context.go('/statistics');
}

/// 今日完整度圆环：环内 `条数/目标`，右下角徽标为连续记录天数。
///
/// 取代原先占满一行的顶部提示条，挂在输入框同一行最左侧。
/// 固定 44×44（与发送按钮同尺寸）保证行内齐底、不额外挤压输入框宽度；
/// 被砍掉的整句文案降级到 Tooltip / Semantics，按需可见。
class TodayProgressRing extends ConsumerWidget {
  const TodayProgressRing({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(diaryProgressProvider);
    final hint = _hintText(progress);

    return Tooltip(
      message: hint,
      child: Semantics(
        label: hint,
        button: true,
        // Material + InkWell 自带命中区：收起态嵌在「展开记录菜单」的手势层里，
        // 才不会把点击漏给外层的展开手势。
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => goStreakFocus(context, ref),
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  _ProgressRing(
                    ratio: progress.ratio,
                    isFull: progress.isFull,
                    label: '${progress.todayCount}/${progress.target}',
                  ),
                  Positioned(
                    right: 1,
                    bottom: 2,
                    child: _StreakBadge(
                      streakDays: progress.streakDays,
                      atRisk: progress.todayPending && progress.streakDays > 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _hintText(DiaryProgress progress) {
    final parts = <String>['今日 ${progress.todayCount}/${progress.target}'];
    if (progress.isFull) {
      parts.add('已完整');
    } else {
      parts.add('再记${progress.remaining}条就完整了');
    }
    if (progress.streakDays > 0) {
      parts.add('连续${progress.streakDays}天${progress.todayPending ? '，今天还没记' : ''}');
    } else {
      parts.add('还没有连续记录');
    }
    return parts.join(' · ');
  }
}

/// 进度环：`CircularProgressIndicator` + 减速补间，满环瞬间鼓起一次再回落。
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.ratio,
    required this.isFull,
    required this.label,
  });

  static const double _size = 34;

  final double ratio;
  final bool isFull;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final ring = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ratio),
      duration: AppDurations.medium,
      curve: AppCurves.emphasized,
      builder: (context, value, child) {
        return SizedBox(
          width: _size,
          height: _size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: value == 0 ? 0.02 : value,
                strokeWidth: 3,
                strokeCap: StrokeCap.round,
                backgroundColor: scheme.outlineVariant.withValues(alpha: 0.7),
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
              ),
              AnimatedSwitcher(
                duration: AppDurations.normal,
                switchInCurve: AppCurves.emphasized,
                switchOutCurve: AppCurves.exit,
                child: Text(
                  label,
                  key: ValueKey(label),
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    color: isFull ? scheme.primary : scheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (!isFull) {
      return ring;
    }
    // Key 挂在外层：翻转 false→true 时从头播一次鼓起，平时不重建内层进度。
    return TweenAnimationBuilder<double>(
      key: const ValueKey('full-pop'),
      tween: Tween(begin: 0, end: 1),
      duration: AppDurations.slow,
      curve: AppCurves.spring,
      builder: (context, t, child) {
        // 0→1 映射为 1→1.12→1：sin 在两端均为 0，结束精确回到原尺寸
        final scale = 1 + 0.12 * math.sin(t * math.pi);
        return Transform.scale(scale: scale, child: child);
      },
      child: ring,
    );
  }
}

/// 连续记录天数徽标：贴在环右下角，不额外占行内宽度。
///
/// [atRisk]（连续未断但今天还没记）时改用描边空心，视觉上提示「再不记就断了」。
class _StreakBadge extends StatelessWidget {
  const _StreakBadge({
    required this.streakDays,
    required this.atRisk,
  });

  final int streakDays;
  final bool atRisk;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inactive = streakDays <= 0;

    final Color background;
    final Color foreground;
    final BoxBorder? border;
    if (inactive) {
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurfaceVariant.withValues(alpha: 0.7);
      border = null;
    } else if (atRisk) {
      background = scheme.surface;
      foreground = scheme.primary;
      border = Border.all(color: scheme.primary, width: 1.2);
    } else {
      background = scheme.primary;
      foreground = scheme.onPrimary;
      border = null;
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(9),
        border: border,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '$streakDays',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            height: 1.1,
            color: foreground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
