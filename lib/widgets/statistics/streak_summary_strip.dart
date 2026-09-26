import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/providers/diary_progress_provider.dart';

/// 记录坚持度指标条，嵌在统计页「评分热力图」卡片头部。
///
/// 四个口径一次摊开：当前连续、最长连续、连续达标、近30天有记录。
/// 「连续」与「连续达标」分开是因为两者口径不同——每天记 1 条能保住连续，
/// 但达不到每日目标；只看其中一个数会误导坚持程度。
class StreakSummaryStrip extends ConsumerStatefulWidget {
  const StreakSummaryStrip({super.key});

  @override
  ConsumerState<StreakSummaryStrip> createState() => _StreakSummaryStripState();
}

class _StreakSummaryStripState extends ConsumerState<StreakSummaryStrip>
    with SingleTickerProviderStateMixin {
  /// 从日记页圆环跳过来时的一次性高亮，值 0→1→0（sin 曲线，两端归零）。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    // 统计页此前停在别的 tab 时，本组件是随切 tab 新建的，
    // ref.listen 收不到「已置值」那一次，这里补播。
    if (ref.read(streakFocusProvider) != null) {
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(streakSummaryProvider);
    final scheme = Theme.of(context).colorScheme;

    ref.listen(streakFocusProvider, (previous, next) {
      // 只认「置值」这一次；统计页消费后置回 null 不应二次播放
      if (next != null) {
        _pulse.forward(from: 0);
      }
    });

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final glow = math.sin(_pulse.value * math.pi);
        return Container(
          padding: EdgeInsets.all(4 + 6 * glow),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.07 * glow),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.55 * glow),
              width: 1,
            ),
          ),
          child: child,
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cell(
                value: summary.recordStreak,
                label: '当前连续',
                valueColor: scheme.primary,
              ),
              _Cell(
                value: summary.recordStreakLongest,
                label: '最长连续',
              ),
              _Cell(
                value: summary.fullStreak,
                label: '连续达标',
              ),
              _Cell(
                value: summary.windowRecordedDays,
                label: '近${summary.windowDays}天',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary.todayPending
                ? '目标 ${summary.target} 条/天 · 近${summary.windowDays}天达标 '
                      '${summary.windowFullDays} 天 · 今天还没记，记一条就续上'
                : '目标 ${summary.target} 条/天 · 近${summary.windowDays}天达标 '
                      '${summary.windowFullDays} 天',
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: summary.todayPending
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个指标格：大数字 + 小标签，等宽平分卡片宽度。
class _Cell extends StatelessWidget {
  const _Cell({
    required this.value,
    required this.label,
    this.valueColor,
  });

  final int value;
  final String label;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '$value',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                height: 1.1,
                color: valueColor ?? scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
