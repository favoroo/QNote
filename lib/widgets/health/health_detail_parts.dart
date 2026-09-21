import 'package:flutter/material.dart';

/// 健康详情页共用的指标小块
///
/// 各详情页都要展示「均值/极值/占比」这类小指标，样式统一在这里，避免每页各写一套
/// 字号与间距（项目主题约定：不硬编码 hex、层级靠色差而不是阴影）。
class HealthStatTile extends StatelessWidget {
  const HealthStatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit = '',
    this.valueColor,
    this.hint,
  });

  final String label;
  final String value;
  final String unit;
  final Color? valueColor;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: valueColor ?? scheme.onSurface,
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 2),
              Text(unit, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(hint!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
        ],
      ],
    );
  }
}

/// 一行等宽排布的指标组
class HealthStatRow extends StatelessWidget {
  const HealthStatRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == children.length - 1 ? 0 : 8),
              child: children[i],
            ),
          ),
      ],
    );
  }
}

/// 详情页的分区卡片：标题 + 内容，浅色底与主看板拉开层级
class HealthDetailSection extends StatelessWidget {
  const HealthDetailSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final Widget child;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              ?trailing,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// 横向占比条：把若干段的相对长度画成一条彩色分段条
class HealthRatioBar extends StatelessWidget {
  const HealthRatioBar({super.key, required this.segments, this.height = 10});

  /// 元素为 (标签, 数值, 颜色)；数值 <= 0 的段自动跳过
  final List<({String label, double value, Color color})> segments;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = segments.fold<double>(0, (a, b) => a + (b.value > 0 ? b.value : 0));
    if (total <= 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Row(
        children: [
          for (final s in segments)
            if (s.value > 0)
              Expanded(
                flex: (s.value / total * 1000).round().clamp(1, 1000),
                child: Container(height: height, color: s.color),
              ),
        ],
      ),
    );
  }
}

/// 占比条下方的图例（色点 + 名称 + 数值文本）
class HealthRatioLegend extends StatelessWidget {
  const HealthRatioLegend({super.key, required this.segments});

  final List<({String label, String text, Color color})> segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final s in segments)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                s.label,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 5),
              Text(
                s.text,
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
      ],
    );
  }
}
