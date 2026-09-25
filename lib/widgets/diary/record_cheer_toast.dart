import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';

/// 记完一次记录后的庆祝事件，由日记页的 listen 逻辑构造。
///
/// [id] 自增，用于区分连续两次内容相同的记录，避免 AnimatedSwitcher
/// 把第二次当成“无变化”吞掉。
class CheerEvent {
  const CheerEvent({
    required this.id,
    required this.title,
    this.sub,
    required this.celebrate,
    this.actionLabel,
  });

  final int id;
  final String title;
  final String? sub;
  final bool celebrate;
  final String? actionLabel;
}

/// 输入条上方浮现的轻量庆祝胶囊。
///
/// 普通记录：小尺寸滑入+1.5s消失；满环/破纪录：稍大尺寸+描边高亮，
/// 由调用方配更长的停留与触感，本组件只负责进场动画与样式。
class RecordCheerToast extends StatelessWidget {
  const RecordCheerToast({
    super.key,
    required this.event,
    this.onAction,
  });

  final CheerEvent event;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TweenAnimationBuilder<double>(
      key: ValueKey(event.id),
      tween: Tween(begin: 0, end: 1),
      duration: AppDurations.normal,
      curve: AppCurves.emphasized,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: Transform.scale(
              scale: event.celebrate ? 0.94 + 0.06 * t : 0.97 + 0.03 * t,
              child: child,
            ),
          ),
        );
      },
      child: Material(
        elevation: 0,
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(event.celebrate ? 16 : 20),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: event.celebrate ? 16 : 14,
            vertical: event.celebrate ? 10 : 8,
          ),
          decoration: event.celebrate
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.5),
                  ),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                event.celebrate
                    ? Icons.celebration_rounded
                    : Icons.check_circle_rounded,
                size: event.celebrate ? 18 : 16,
                color: scheme.inversePrimary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onInverseSurface,
                      ),
                    ),
                    if (event.sub != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.sub!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onInverseSurface.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (event.actionLabel != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onAction,
                  child: Text(
                    event.actionLabel!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.inversePrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
