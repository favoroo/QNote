import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/token_usage_format.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_token_usage.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';

/// 打开 Token 消耗明细弹层
///
/// 用底部弹层而不是新页面：入口在配置页首屏，用户看完排行通常还要继续改配置，
/// 弹层关闭后原页面与滚动位置保持不变。
Future<void> showTokenUsageDetailSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const TokenUsageDetailSheet(),
  );
}

/// Token 消耗明细弹层：时间范围筛选 + 总量 + 厂商 / 模型排行
///
/// 数据口径与统计卡一致，只统计服务端上报的 usage；本机观测数据不参与云同步。
class TokenUsageDetailSheet extends ConsumerStatefulWidget {
  const TokenUsageDetailSheet({super.key});

  @override
  ConsumerState<TokenUsageDetailSheet> createState() =>
      _TokenUsageDetailSheetState();
}

class _TokenUsageDetailSheetState extends ConsumerState<TokenUsageDetailSheet> {
  /// 默认看累计：与统计卡顶部的「本机累计」保持一致
  AiTokenUsagePeriod _period = AiTokenUsagePeriod.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailAsync = ref.watch(aiTokenUsageDetailProvider(_period));
    final providers =
        ref.watch(aiProviderListProvider).valueOrNull ?? const <AiProvider>[];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return Column(
          children: [
            const _SheetHeader(),
            _periodSelector(theme),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: detailAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 56),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  error: (error, stackTrace) => _ErrorState(
                    onRetry: () =>
                        ref.invalidate(aiTokenUsageDetailProvider(_period)),
                  ),
                  data: (detail) => TokenUsageDetailView(
                    detail: detail,
                    providers: providers,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _periodSelector(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final period in AiTokenUsagePeriod.values)
              ChoiceChip(
                label: Text(period.label),
                selected: _period == period,
                visualDensity: VisualDensity.compact,
                onSelected: (selected) {
                  if (!selected || _period == period) return;
                  setState(() => _period = period);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// 弹层标题栏
class _SheetHeader extends StatelessWidget {
  const _SheetHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Token 消耗明细',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '本机统计 · 仅含服务端上报用量',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

/// 明细内容（纯展示组件，便于不拉起数据库单独测试）
class TokenUsageDetailView extends StatelessWidget {
  final AiTokenUsageDetail detail;
  final List<AiProvider> providers;

  const TokenUsageDetailView({
    super.key,
    required this.detail,
    this.providers = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!detail.hasData) {
      return _EmptyState(period: detail.period);
    }

    final providerById = {
      for (final provider in providers) provider.id: provider,
    };
    final total = detail.summary.totalTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(detail: detail),
        const SizedBox(height: 18),
        _SectionHeader(title: '厂商排行', count: detail.providers.length),
        const SizedBox(height: 4),
        for (int i = 0; i < detail.providers.length; i++)
          _RankRow(
            rank: i + 1,
            title: _providerName(providerById, detail.providers[i].providerId),
            subtitle:
                '${detail.providers[i].requestCount} 次请求 · '
                '平均 ${formatTokenCount(detail.providers[i].averagePerRequest)}/次',
            item: detail.providers[i],
            totalTokens: total,
          ),
        const SizedBox(height: 18),
        _SectionHeader(title: '模型排行', count: detail.models.length),
        const SizedBox(height: 4),
        for (int i = 0; i < detail.models.length; i++)
          _RankRow(
            rank: i + 1,
            title: _modelName(providerById, detail.models[i]),
            subtitle:
                '${_providerName(providerById, detail.models[i].providerId)} · '
                '${detail.models[i].requestCount} 次请求',
            item: detail.models[i],
            totalTokens: total,
          ),
        const SizedBox(height: 16),
        Text(
          '统计为本机数据，不参与云同步；仅当服务商返回 usage 时计入。',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 厂商展示名：条目被删除后历史用量仍保留，此时回退到 id
  String _providerName(Map<String, AiProvider> byId, String providerId) {
    final name = byId[providerId]?.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    return providerId.trim().isEmpty ? '未知厂商' : providerId;
  }

  /// 模型展示名：优先取厂商条目里的自定义名，删掉后回退到模型 ID
  String _modelName(Map<String, AiProvider> byId, AiTokenUsageBreakdown item) {
    final provider = byId[item.providerId];
    final model = provider?.models
        .where((model) => model.id == item.modelName)
        .firstOrNull;
    final name = model?.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    return item.modelName.trim().isEmpty ? '未知模型' : item.modelName;
  }
}

/// 总量卡片：总计 + 输入 / 输出 / 平均每次
class _SummaryCard extends StatelessWidget {
  final AiTokenUsageDetail detail;

  const _SummaryCard({required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final summary = detail.summary;
    final tintAlpha = theme.brightness == Brightness.dark ? 0.12 : 0.05;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: tintAlpha),
        borderRadius: BorderRadius.circular(AppRadius.medium),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '总消耗',
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Tooltip(
                message: '${formatTokenCountExact(summary.totalTokens)} tokens',
                child: Text(
                  formatTokenCount(summary.totalTokens),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'tokens',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '${summary.requestCount} 次请求',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SummaryMetric(label: '输入', value: summary.promptTokens),
              ),
              _verticalDivider(theme),
              Expanded(
                child: _SummaryMetric(
                  label: '输出',
                  value: summary.completionTokens,
                ),
              ),
              _verticalDivider(theme),
              Expanded(
                child: _SummaryMetric(
                  label: '平均/次',
                  value: detail.averagePerRequest,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _verticalDivider(ThemeData theme) {
    return Container(
      width: 1,
      height: 26,
      margin: const EdgeInsets.only(right: 8),
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
  }
}

/// 总量卡片里的单个指标
class _SummaryMetric extends StatelessWidget {
  final String label;
  final int value;

  const _SummaryMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '${formatTokenCountExact(value)} tokens',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatTokenCount(value),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 排行分区标题
class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _SectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Text(
          '$count 项',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 一行排行：名次、名称、token 数、占比条与请求数
class _RankRow extends StatelessWidget {
  final int rank;
  final String title;
  final String subtitle;
  final AiTokenUsageBreakdown item;
  final int totalTokens;

  const _RankRow({
    required this.rank,
    required this.title,
    required this.subtitle,
    required this.item,
    required this.totalTokens,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final share = totalTokens <= 0 ? 0.0 : item.totalTokens / totalTokens;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: rank <= 3 ? colorScheme.primary : colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          '总计 ${formatTokenCountExact(item.totalTokens)}\n'
                          '输入 ${formatTokenCountExact(item.promptTokens)}\n'
                          '输出 ${formatTokenCountExact(item.completionTokens)}',
                      child: Text(
                        formatTokenCount(item.totalTokens),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: share.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _percentText(share),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _percentText(double share) {
    final percent = share * 100;
    if (percent > 0 && percent < 0.1) return '<0.1%';
    return '${percent.toStringAsFixed(1)}%';
  }
}

/// 该时间范围没有记录
class _EmptyState extends StatelessWidget {
  final AiTokenUsagePeriod period;

  const _EmptyState({required this.period});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = period == AiTokenUsagePeriod.all
        ? '暂无消耗记录'
        : '${period.label}暂无消耗记录';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.data_usage_rounded, size: 34, color: colorScheme.outline),
          const SizedBox(height: 10),
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '服务商返回 usage 后会自动累计；不支持上报用量的服务商不会计入。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 读库失败（正常路径由仓储吞异常并退化为空态，这里只兜住意外）
class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.error_outline_rounded, size: 32, color: colorScheme.error),
          const SizedBox(height: 8),
          Text(
            '读取消耗明细失败',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
