import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 助手消息气泡下方的语音朗读按钮。
///
/// 三态复用一个紧凑按钮：空闲（朗读）/ 合成中（转圈）/ 播放中（停止）。
/// 播放状态全局唯一（ttsPlaybackProvider），历史回复同样可点读。
class BubbleVoiceButton extends ConsumerWidget {
  final ChatMessage message;

  const BubbleVoiceButton({super.key, required this.message});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final playback = ref.watch(ttsPlaybackProvider);
    final key = TtsPlayer.messageKeyOf(message);
    final isMine = playback.messageId == key;
    final status = isMine ? playback.status : TtsPlaybackStatus.idle;

    // 合成/播放失败时以 Toast 提示一次（state 变化即触发，无需手动去重）
    ref.listen<TtsPlaybackState>(ttsPlaybackProvider, (prev, next) {
      final error = next.error;
      if (error != null && error.isNotEmpty) {
        Toast.error(context, '语音朗读失败：$error');
      }
    });

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, bottom: 8),
      child: FilledButton.tonalIcon(
        onPressed: () => ref.read(ttsPlaybackProvider.notifier).toggleMessage(message),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: theme.textTheme.labelMedium,
        ),
        icon: _buildIcon(status, theme),
        label: Text(
          switch (status) {
            TtsPlaybackStatus.synthesizing => '生成中',
            TtsPlaybackStatus.playing => '停止',
            TtsPlaybackStatus.idle => '朗读',
          },
        ),
      ),
    );
  }

  Widget _buildIcon(TtsPlaybackStatus status, ThemeData theme) {
    switch (status) {
      case TtsPlaybackStatus.synthesizing:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.primary,
          ),
        );
      case TtsPlaybackStatus.playing:
        return const Icon(Icons.stop_rounded, size: 18);
      case TtsPlaybackStatus.idle:
        return const Icon(Icons.volume_up_rounded, size: 18);
    }
  }
}
