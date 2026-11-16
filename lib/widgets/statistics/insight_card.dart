import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/knowledge/kg_config.dart';
import 'package:qnote_flutter/core/knowledge/kg_indexer.dart';
import 'package:qnote_flutter/core/knowledge/kg_insight_service.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/knowledge_graph_provider.dart';

/// 统计页「关联发现」小卡片。
///
/// 刻意只展示 3 条：不新增导航、不要求用户学习图谱概念；想看证据就点开，
/// 想深挖就问小Q，不想看就忽略。图谱不会自动更新，卡片底部提供手动更新入口。
class InsightCard extends ConsumerWidget {
  const InsightCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(kgInsightsProvider);
    final statusAsync = ref.watch(kgStatusProvider);
    final progress = ref.watch(kgProgressProvider);

    return ValueListenableBuilder<KgRunProgress?>(
      valueListenable: progress,
      builder: (context, runProgress, _) {
        return insightsAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (insights) {
            if (insights.isNotEmpty) {
              return _buildCard(context, ref, insights, statusAsync.valueOrNull, runProgress);
            }
            final status = statusAsync.valueOrNull;
            if (status == null) return const SizedBox.shrink();
            final enabled = status['enabled'] != false;
            final hasSource = status['has_source_data'] == true;
            final documentCount = (status['document_count'] as num?)?.toInt() ?? 0;
            // 已有图谱但没有洞察 = 数据量还不够，保持隐藏；只有「有数据但还没建图」才引导一次
            if (!enabled || !hasSource || documentCount > 0) return const SizedBox.shrink();
            return _buildEmptyCard(context, ref, runProgress);
          },
        );
      },
    );
  }

  Widget _buildCard(
    BuildContext context,
    WidgetRef ref,
    List<KgInsight> insights,
    Map<String, dynamic>? status,
    KgRunProgress? progress,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final lastScan = DateTime.tryParse(status?['last_scan_at']?.toString() ?? '');
    final pending = (status?['pending_rule_count'] as num?)?.toInt() ?? 0;
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_rounded, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '关联发现',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: AppTypography.subtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '近半年',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: AppTypography.caption,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              '从你的记录里找到的相关性，仅供参考',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: AppTypography.caption,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            for (final insight in insights.take(3))
              _InsightRow(insight: insight, onTap: () => _showInsightSheet(context, ref, insight)),
            Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.25)),
            _buildFooter(context, ref, lastScan: lastScan, pending: pending, progress: progress),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCard(BuildContext context, WidgetRef ref, KgRunProgress? progress) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_rounded, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '关联发现',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: AppTypography.subtitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把时间线、笔记和健康数据连起来，找出你自己可能没注意到的规律。',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: AppTypography.caption,
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            if (progress != null)
              _buildInlineProgress(theme, progress)
            else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(onPressed: () => _refresh(context, ref), child: const Text('建立图谱')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    WidgetRef ref, {
    required DateTime? lastScan,
    required int pending,
    required KgRunProgress? progress,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (progress != null) return _buildInlineProgress(theme, progress);

    final pendingText = pending > 0 ? ' · 有约 $pending 条新记录' : '';
    return Row(
      children: [
        Expanded(
          child: Text(
            lastScan == null ? '尚未更新' : '更新于 ${_formatDateTime(lastScan)}$pendingText',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: AppTypography.caption,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: () => _refresh(context, ref),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          child: const Text('更新'),
        ),
      ],
    );
  }

  Widget _buildInlineProgress(ThemeData theme, KgRunProgress progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              progress.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: AppTypography.caption,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: KnowledgeGraphIndexer.instance.cancel,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('停止'),
          ),
        ],
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    if (KnowledgeGraphIndexer.instance.isRunning) return;
    if (!await KgConfig.isEnabled()) {
      if (context.mounted) Toast.warning(context, '请先在设置中启用知识图谱');
      return;
    }
    final report = await KnowledgeGraphIndexer.instance.run();
    if (!context.mounted) return;
    final parts = <String>[
      if (report.updated > 0) '${report.updated} 条记录',
      if (report.removed > 0) '清理 ${report.removed} 条',
    ];
    final summary = parts.join('，');
    if (report.error != null) {
      Toast.error(context, '更新失败：${report.error}');
    } else if (report.cancelled) {
      Toast.info(context, '已停止更新');
    } else if (report.failed > 0) {
      Toast.warning(context, summary.isEmpty ? '更新失败 ${report.failed} 条' : '$summary，失败 ${report.failed} 条');
    } else if (!report.hasChanges) {
      Toast.success(context, '图谱已是最新');
    } else {
      Toast.success(context, summary.isEmpty ? '图谱已更新' : '图谱已更新：$summary');
    }
    ref.invalidate(kgStatusProvider);
    ref.invalidate(kgInsightsProvider);
  }

  static String _formatDateTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  Future<void> _showInsightSheet(BuildContext context, WidgetRef ref, KgInsight insight) async {
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final colorScheme = theme.colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _KindBadge(kind: insight.kind),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          insight.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: AppTypography.title,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    insight.body,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: AppTypography.body, height: 1.55),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '支持 ${insight.support} 天 · 置信度 ${(insight.confidence * 100).round()}%'
                    ' · 提升度 ${insight.lift.toStringAsFixed(1)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: AppTypography.caption,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (insight.evidence.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      '证据',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: AppTypography.bodyLarge,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final evidence in insight.evidence.take(5)) _EvidenceRow(evidence: evidence),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            Navigator.of(sheetContext).pop();
                            await KnowledgeGraphInsightService.instance.dismiss(insight.id);
                            ref.invalidate(kgInsightsProvider);
                          },
                          child: const Text('不感兴趣'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _askQ(ref, insight);
                          },
                          child: const Text('问小Q'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _askQ(WidgetRef ref, KgInsight insight) {
    final dates = insight.evidence
        .map((e) => e.occurredDate)
        .whereType<String>()
        .where((d) => d.isNotEmpty)
        .toSet()
        .take(5)
        .join('、');
    final quoted = [insight.title, insight.body, if (dates.isNotEmpty) '证据日期：$dates'].join('\n');
    ref
        .read(floatingQProvider.notifier)
        .openWithQuote(
          QTextQuote(
            source: QQuoteSource.external,
            sourceId: insight.id,
            sourceTitle: insight.title,
            quotedText: quoted.length > 500 ? '${quoted.substring(0, 500)}…' : quoted,
          ),
        );
  }
}

class _InsightRow extends StatelessWidget {
  final KgInsight insight;
  final VoidCallback onTap;

  const _InsightRow({required this.insight, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            _KindBadge(kind: insight.kind, compact: true),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    insight.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: AppTypography.bodyLarge, height: 1.35),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '支持 ${insight.support} 天 · ${(insight.confidence * 100).round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: AppTypography.caption,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  final String kind;
  final bool compact;

  const _KindBadge({required this.kind, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (kind) {
      KgInsightKind.lagged => (Icons.schedule_rounded, colorScheme.tertiary),
      KgInsightKind.bridge => (Icons.hub_rounded, colorScheme.secondary),
      KgInsightKind.trend => (Icons.trending_up_rounded, colorScheme.primary),
      _ => (Icons.link_rounded, colorScheme.primary),
    };
    final size = compact ? 28.0 : 36.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: compact ? 0.12 : 0.10),
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
      ),
      child: Icon(icon, size: compact ? 16 : 20, color: color),
    );
  }
}

class _EvidenceRow extends StatelessWidget {
  final KgEvidence evidence;

  const _EvidenceRow({required this.evidence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final path = evidence.path.isEmpty ? evidence.sourceType : evidence.path;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.description_outlined, size: 15, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${evidence.occurredDate ?? ''} $path'.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: AppTypography.caption,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (evidence.snippet.trim().isNotEmpty)
                  Text(
                    evidence.snippet.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: AppTypography.caption),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
