import 'package:flutter/material.dart';

/// 异步加载失败的统一占位组件，替代此前各页面裸文本 `Text('加载失败: $e')`。
///
/// 只负责「说清失败 + 给出重试出口」，不承载空态语义（空态用 EmptyStateWidget，
/// 它带常驻呼吸动画，错误态不应呼吸）。
class AppErrorState extends StatelessWidget {
  /// 原始异常，仅用于向用户暴露可反馈的线索
  final Object error;

  /// 点击「重试」的回调，通常传 `() => ref.invalidate(provider)`
  final VoidCallback onRetry;

  /// 失败动作描述，用于区分同一页面内多个数据源（如「加载分类」与「加载笔记」）
  final String action;

  /// 紧凑模式：用于抽屉、Stack 内局部区域等不允许整屏替换的场景
  final bool compact;

  const AppErrorState({
    super.key,
    required this.error,
    required this.onRetry,
    this.action = '加载失败',
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final detail = Text(
      '$action：$error',
      style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
      textAlign: TextAlign.center,
      maxLines: compact ? 2 : 4,
      overflow: TextOverflow.ellipsis,
    );

    if (compact) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 20, color: colorScheme.error),
              const SizedBox(height: 6),
              detail,
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline_rounded, size: 26, color: colorScheme.onErrorContainer),
            ),
            const SizedBox(height: 14),
            Text(
              action,
              style: theme.textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            // 长异常串限高，避免撑破列表区域；完整内容可从日志查看
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: detail),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
