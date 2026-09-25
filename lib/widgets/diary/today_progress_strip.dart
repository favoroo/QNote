import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/providers/diary_progress_provider.dart';

/// 日记页顶部今日完整度细条。
///
/// 左侧圆环显示今日 `count/目标`，右侧火苗显示连续天数；
/// 点击整条跳转统计页。背景用低层级容器色，不抢时间线注意力。
class TodayProgressStrip extends ConsumerWidget {
  const TodayProgressStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(diaryProgressProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final mainText = _mainText(progress.todayCount, progress.target);
    final streakText = _streakText(
      progress.streakDays,
      progress.todayPending,
    );

    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => context.go('/statistics'),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
          child: Row(
            children: [
              _ProgressRing(
                ratio: progress.ratio,
                isFull: progress.isFull,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppDurations.normal,
                  switchInCurve: AppCurves.emphasized,
                  switchOutCurve: AppCurves.exit,
                  child: Text(
                    mainText,
                    key: ValueKey(mainText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: progress.isFull
                          ? scheme.primary
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.local_fire_department_rounded,
                size: 16,
                color: progress.streakDays > 0
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 4),
              Text(
                streakText,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: progress.streakDays > 0
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _mainText(int count, int target) {
    if (count <= 0) {
      return '今天还没有记录，记下第一条吧';
    }
    if (count < target) {
      return '今日 $count/$target · 再记${target - count}条就完整了';
    }
    if (count == target) {
      return '今日已完整 · 共$count条';
    }
    return '今日已完整 · 共$count条，超出目标！';
  }

  String _streakText(int streak, bool todayPending) {
    if (streak <= 0) {
      return '连续0天';
    }
    if (todayPending) {
      return '连续$streak天·今日未记';
    }
    return '连续$streak天';
  }
}

/// 今日圆环：进度用减速曲线补间，满环瞬间加一次弹性鼓起后回到原尺寸。
///
/// 进度条自身不带 Key，保证 `ratio` 变化时从当前值平滑补间，
/// 不会在满环翻转时从 0 重扫。
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.ratio,
    required this.isFull,
  });

  final double ratio;
  final bool isFull;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ring = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ratio),
      duration: AppDurations.medium,
      curve: AppCurves.emphasized,
      builder: (context, value, _) {
        return SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            value: value == 0 ? 0.02 : value,
            strokeWidth: isFull ? 4 : 3.5,
            strokeCap: StrokeCap.round,
            backgroundColor: scheme.outlineVariant.withValues(alpha: 0.7),
            valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
          ),
        );
      },
    );

    // 非满环直接返回；满环时包一层“鼓起后回落”的一次性动画。
    // Key 挂在外层，翻转 false→true 时从头播放一次，平时不重建内层进度。
    if (!isFull) {
      return ring;
    }
    return TweenAnimationBuilder<double>(
      key: const ValueKey('full-pop'),
      tween: Tween(begin: 0, end: 1),
      duration: AppDurations.slow,
      curve: AppCurves.spring,
      builder: (context, t, child) {
        // 0→1 映射为 1→1.12→1 的鼓起：sin 在 t=0/1 处均为 0，结束精确回到原尺寸
        final scale = 1 + 0.12 * math.sin(t * math.pi);
        return Transform.scale(scale: scale, child: child);
      },
      child: ring,
    );
  }
}
