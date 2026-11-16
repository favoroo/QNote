import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_typography.dart';
import 'package:qnote_flutter/widgets/common/morphing_infinity.dart';
import 'package:qnote_flutter/widgets/common/streaming_elapsed_text.dart';

/// 「工作中 · N s」身份行徽章：挂在小Q名字右侧（主对话组抬头 / 悬浮面板标题栏），
/// 替代原工作流折叠行下方的「工作中」副行，从任务开始即时可见，不再等首个工具动作。
///
/// - 计时为任务级（思考→工具切换不清零），数字零缓冲立即显示：徽章本身的出现
///   就代表任务刚开始，无需再防闪烁；
/// - 限流时文本替换为「服务商限流 · Ns 后重试」倒计时；
/// - [startedAt] 为 null（无进行中任务）或 [active] 为 false（正文开始流式，
///   进行中信号由正文本身承载）时返回空，宿主可常驻挂载无需自行判断。
class AgentWorkingBadge extends StatelessWidget {
  /// 任务级计时起点（agentStart 记录）；为 null 时不渲染
  final DateTime? startedAt;

  /// 阶段性状态文案，仅用于识别并展示限流倒计时
  final String? statusText;

  /// 正文开始流式后置 false 隐藏徽章
  final bool active;

  const AgentWorkingBadge({super.key, required this.startedAt, this.statusText, this.active = true});

  @override
  Widget build(BuildContext context) {
    if (!active || startedAt == null) return const SizedBox.shrink();
    final status = statusText?.trim() ?? '';
    // 限流文案自带倒计时，替换「工作中」展示；前缀判断与工作流副行口径一致
    final hasRateLimit = status.startsWith('服务商限流');
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MorphingInfinity(size: 12, strokeWidth: 1.3, color: theme.accentInk),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            hasRateLimit ? status : '工作中',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppTypography.label, color: colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 4),
        StreamingElapsedText(
          startedAt: startedAt,
          gracePeriod: Duration.zero,
          style: TextStyle(fontSize: AppTypography.label, color: colorScheme.outline),
        ),
      ],
    );
  }
}
