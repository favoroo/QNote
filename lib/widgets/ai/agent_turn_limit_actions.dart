import 'package:flutter/material.dart';

/// Agent 步数上限「继续/暂停」操作行
///
/// Agent 达到单次任务步数上限时，随超限提示消息渲染在气泡下方。
/// 主页面（ai_page）与悬浮小Q面板（floating_q_overlay）共用，
/// 保证两处入口的按钮样式与交互一致。
class AgentTurnLimitActions extends StatelessWidget {
  /// 点击「继续」：以当前会话历史重启 Agent 循环接着执行
  final VoidCallback? onContinue;

  /// 点击「暂停」：隐藏按钮，已完成的工作保留，任务就此结束
  final VoidCallback? onPause;

  /// 是否可点（Agent 执行中禁用，防止并发任务）
  final bool enabled;

  const AgentTurnLimitActions({
    super.key,
    required this.onContinue,
    required this.onPause,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, bottom: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonalIcon(
            onPressed: enabled ? onContinue : null,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: theme.textTheme.labelMedium,
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('继续'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: enabled ? onPause : null,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: theme.textTheme.labelMedium,
            ),
            icon: const Icon(Icons.pause_rounded, size: 18),
            label: const Text('暂停'),
          ),
        ],
      ),
    );
  }
}
