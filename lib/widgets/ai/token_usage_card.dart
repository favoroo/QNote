import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/token_usage_format.dart';
import 'package:qnote_flutter/models/ai_token_usage.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/token_usage_detail_sheet.dart';

/// AI 配置页顶部的 Token 消耗统计卡
///
/// 口径刻意保持克制：只展示**服务端上报**的累计输入 / 输出 / 总计与请求数，
/// 再补今日与近 7 天两个窗口。不猜价格、不估算缺失用量——不同模型分词器与
/// 计费规则差异太大，估算值混进来反而让用户不敢信这张卡。
///
/// 点击卡片打开 [TokenUsageDetailSheet]，按时间范围查看厂商 / 模型排行。
/// 数据来自本机 `ai_token_usage_daily` 表（不参与云同步），因此文案明确写「本机」。
class TokenUsageCard extends ConsumerWidget {
  const TokenUsageCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summaryAsync = ref.watch(aiTokenUsageSummaryProvider);

    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showTokenUsageDetailSheet(context),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: summaryAsync.when(
            loading: () => const SizedBox(
              height: 96,
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
            // 统计读失败不该在配置页摆一块红脸：退化成空态即可，不影响模型配置本身
            error: (e, st) => _content(theme, AiTokenUsageSummary.empty),
            data: (summary) => _content(theme, summary),
          ),
        ),
      ),
    );
  }

  Widget _content(ThemeData theme, AiTokenUsageSummary summary) {
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.data_usage_rounded, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            Text('Token 消耗', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('本机累计', style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded, size: 16, color: colorScheme.onSurfaceVariant),
          ],
        ),
        const SizedBox(height: 10),
        if (!summary.hasData)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '暂无消耗记录。仅统计服务端返回的用量。',
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Tooltip(
                message: '${formatTokenCountExact(summary.totalTokens)} tokens',
                child: Text(
                  formatTokenCount(summary.totalTokens),
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: -0.5),
                ),
              ),
              const SizedBox(width: 4),
              Text('tokens', style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
              const Spacer(),
              Text(
                '${summary.requestCount} 次请求',
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _metric(theme, label: '输入', value: summary.promptTokens, exact: summary.promptTokens),
              ),
              _verticalDivider(theme),
              Expanded(
                child: _metric(theme, label: '输出', value: summary.completionTokens, exact: summary.completionTokens),
              ),
              _verticalDivider(theme),
              Expanded(
                child: _metric(theme, label: '今日', value: summary.todayTokens, exact: summary.todayTokens),
              ),
              _verticalDivider(theme),
              Expanded(
                child: _metric(theme, label: '近 7 天', value: summary.weekTokens, exact: summary.weekTokens),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _metric(ThemeData theme, {required String label, required int value, required int exact}) {
    return Tooltip(
      message: formatTokenCountExact(exact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(formatTokenCount(value), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 1),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
