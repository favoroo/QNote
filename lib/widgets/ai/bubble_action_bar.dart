import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 助手气泡内的底部操作条：复制 / 朗读 / 重新生成（纯图标）。
///
/// 直接内嵌在气泡卡片里作为底部一段（由气泡卡片统一裁圆角），顶部一条
/// 发丝线 + 浅一档底色划分区域，替代原先挂在气泡下方的连体小卡。
class BubbleActionBar extends ConsumerWidget {
  final ChatMessage message;

  /// 重新生成回调；为 null 时不渲染该入口（仅会话最后一条回复提供）
  final VoidCallback? onRegenerate;

  /// 重新生成是否可点（流式输出中禁用，避免与进行中的任务并发）
  final bool regenerateEnabled;

  const BubbleActionBar({super.key, required this.message, this.onRegenerate, this.regenerateEnabled = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final playback = ref.watch(ttsPlaybackProvider);
    final key = TtsPlayer.messageKeyOf(message);
    final status = playback.messageId == key ? playback.status : TtsPlaybackStatus.idle;

    // 合成/播放失败时以 Toast 提示一次（state 变化即触发，无需手动去重）
    ref.listen<TtsPlaybackState>(ttsPlaybackProvider, (prev, next) {
      final error = next.error;
      if (error != null && error.isNotEmpty) {
        Toast.error(context, '语音朗读失败：$error');
        return;
      }
      // 降级说明在本场朗读期间一直挂在状态上（段间刷新会重复上报），故比对去重：
      // 用户选了在线音色却听到设备语音时，这是他唯一能看到的解释
      final notice = next.notice;
      if (notice != null && notice != prev?.notice) {
        Toast.warning(context, notice);
      }
    });

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        // 比气泡浅一档 + 发丝线分隔：在卡片内部划出底部操作区，不再自带描边圆角
        // （外层气泡卡片统一裁圆角）
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4), width: 0.8)),
      ),
      child: Row(
        children: [
          _BarButton(
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message.content));
              Toast.success(context, '已复制');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
          const SizedBox(width: 2),
          _BarButton(
            tooltip: switch (status) {
              TtsPlaybackStatus.synthesizing => '语音生成中',
              TtsPlaybackStatus.playing => '停止朗读',
              TtsPlaybackStatus.idle => '朗读',
            },
            // 播放中高亮底色：全局单朗读通道，一眼看出正在听哪一条
            active: status == TtsPlaybackStatus.playing,
            onPressed: () => ref.read(ttsPlaybackProvider.notifier).toggleMessage(message),
            icon: switch (status) {
              TtsPlaybackStatus.synthesizing => SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
              ),
              TtsPlaybackStatus.playing => const Icon(Icons.stop_rounded, size: 18),
              TtsPlaybackStatus.idle => const Icon(Icons.volume_up_rounded, size: 18),
            },
          ),
          // 重新生成是「一轮一次」的动作，靠右与随手可点的复制/朗读分区
          if (onRegenerate != null) ...[
            const Spacer(),
            _BarButton(
              tooltip: '重新生成',
              onPressed: regenerateEnabled ? onRegenerate : null,
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

/// 操作条内的纯图标按钮（32×32，图标 18，靠 Tooltip 表意）
class _BarButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;

  /// 播放中等需要强调的态：改用 primaryContainer 底色
  final bool active;

  const _BarButton({required this.tooltip, required this.onPressed, required this.icon, this.active = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        iconSize: 18,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: active ? scheme.primaryContainer : null,
        foregroundColor: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
      icon: icon,
    );
  }
}
