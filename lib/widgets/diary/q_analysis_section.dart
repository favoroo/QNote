import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';

/// 时间线卡片与编辑器里的「小Q分析」折叠区。
///
/// 小Q 的图片解读、营养/健康评估属于「附加信息」：默认收起，避免抢走用户
/// 自己正文的注意力；标题行始终可见，让用户知道这条记录有小Q的补充分析。
class QAnalysisSection extends StatelessWidget {
  /// 分析文本行（调用方已按行拆分并去重）。
  final List<String> lines;

  /// 是否展开。组件本身不持有展开状态，方便卡片/编辑器在重建后保留选择。
  final bool expanded;

  /// 展开/收起回调。
  final ValueChanged<bool> onExpandedChanged;

  /// 可选的「清除分析」入口；仅编辑器传入。
  final VoidCallback? onClear;

  /// 紧凑模式：用于快捷记录面板等空间有限的位置。
  final bool compact;

  const QAnalysisSection({
    super.key,
    required this.lines,
    required this.expanded,
    required this.onExpandedChanged,
    this.onClear,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 小Q 分析是品牌附加信息：用可读强调色而不是标签色，避免和记录本身
    // 的彩色胶囊抢视觉层级
    final ink = theme.accentInk;
    const radius = 12.0;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ink.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onExpandedChanged(!expanded),
              borderRadius: BorderRadius.circular(radius),
              child: Semantics(
                button: true,
                expanded: expanded,
                label: expanded ? '收起小Q分析' : '展开小Q分析',
                child: Padding(
                  padding: EdgeInsets.fromLTRB(compact ? 9 : 10, compact ? 6 : 7, compact ? 7 : 8, compact ? 6 : 7),
                  child: Row(
                    children: [
                      QIcon(size: 14, color: ink),
                      const SizedBox(width: 6),
                      Text(
                        '小Q分析',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: ink,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const Spacer(),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: AppMotion.duration(context, AppDurations.normal),
                        curve: AppCurves.emphasized,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AppCollapsible(
            expanded: expanded,
            rise: 4,
            child: Padding(
              padding: EdgeInsets.fromLTRB(compact ? 10 : 12, 0, compact ? 10 : 12, compact ? 8 : 10),
              // 面板/弹窗里空间有限：给分析内容一个上限并允许内部滚动，
              // 避免长分析把输入区顶出屏幕
              child: compact
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(child: _buildExpandedContent(theme, scheme, ink)),
                    )
                  : _buildExpandedContent(theme, scheme, ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedContent(ThemeData theme, ColorScheme scheme, Color ink) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧细竖线做成引用块：分析是「小Q说的话」，与用户正文区分开
        Container(
          padding: const EdgeInsets.only(left: 9),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: ink.withValues(alpha: 0.3), width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: i == lines.length - 1 ? 0 : 4),
                  child: Text(
                    lines[i],
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: AppTypography.body,
                      height: 1.6,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (onClear != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: const Text('清除分析'),
            ),
          ),
      ],
    );
  }
}
