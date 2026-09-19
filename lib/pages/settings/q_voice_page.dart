import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/core/tts/tts_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 小Q语音回复设置
///
/// 提供自动朗读开关、Edge 音色选择（带试听）与语速档位；
/// Web 端在线合成不可用，朗读走浏览器自带语音并在此说明。
class QVoicePage extends ConsumerStatefulWidget {
  const QVoicePage({super.key, this.embedded = false});

  /// 嵌入模式：由综合设置页承载时为 true，不重复生成外层 Scaffold 与 AppBar
  final bool embedded;

  @override
  ConsumerState<QVoicePage> createState() => _QVoicePageState();
}

class _QVoicePageState extends ConsumerState<QVoicePage> {
  QVoiceSettings? _settings;

  @override
  void initState() {
    super.initState();
    QVoiceConfig.instance.get().then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  QVoiceSettings get _current => _settings ?? QVoiceSettings.defaults;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final body = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildCard(
          context,
          child: SwitchListTile(
            value: _current.autoRead,
            onChanged: _saveAutoRead,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text('自动朗读回复', style: theme.textTheme.bodyLarge),
            subtitle: Text(
              '小Q回复完成后用语音读出',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildCard(
          context,
          child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text('音色', style: theme.textTheme.bodyLarge),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      kOnlineSynthesisSupported
                          ? TtsService.voiceById(_current.voice).label
                          : '浏览器语音',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: _showVoicePicker,
              ),
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text('语速', style: theme.textTheme.bodyLarge),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      QVoiceConfig.rateOptions[_current.rate] ?? '正常',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: _showRatePicker,
              ),
            ],
          ),
        ),
        // Web 端无 Edge 在线合成通道，音色由浏览器决定，需要向用户说明差异
        if (!kOnlineSynthesisSupported) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Web 端使用浏览器自带语音朗读，音色与语速跟随浏览器设置。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('小Q语音'),
        centerTitle: false,
      ),
      body: body,
    );
  }

  Widget _buildCard(BuildContext context, {required Widget child}) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      // ListTile 的水波纹画在最近的 Material 上，包一层透明 Material
      // 避免被带背景色的 DecoratedBox 遮挡（调试断言要求）
      child: Material(
        type: MaterialType.transparency,
        child: child,
      ),
    );
  }

  Future<void> _saveAutoRead(bool enabled) async {
    try {
      await QVoiceConfig.instance.setAutoRead(enabled);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(autoRead: enabled));
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  /// 音色选择弹窗：每行带试听按钮，试听与停止共用同一播放通道
  void _showVoicePicker() {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.2,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Text(
                  '选择音色',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final voice in TtsService.builtinVoices)
                      ListTile(
                        leading: _buildPreviewButton(voice),
                        title: Text(voice.label),
                        subtitle: Text(
                          voice.note,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: voice.id == _current.voice
                            ? Icon(
                                Icons.check_circle,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                        onTap: () => _selectVoice(voice.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 音色试听按钮：播放固定示例句，播放中变为停止
  Widget _buildPreviewButton(TtsVoiceOption voice) {
    final playback = ref.watch(ttsPlaybackProvider);
    final previewKey = 'preview_${voice.id}';
    final isPlaying =
        playback.messageId == previewKey &&
        playback.status == TtsPlaybackStatus.playing;
    final isBusy = playback.messageId == previewKey &&
        playback.status == TtsPlaybackStatus.synthesizing;

    return IconButton.filledTonal(
      iconSize: 20,
      onPressed: () {
        final notifier = ref.read(ttsPlaybackProvider.notifier);
        if (isPlaying || isBusy) {
          notifier.stop();
          return;
        }
        notifier.speakMessage(
          previewKey,
          '你好，我是小Q，很高兴认识你。',
          voiceOverride: voice.id,
        );
      },
      icon: isBusy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded),
    );
  }

  Future<void> _selectVoice(String voiceId) async {
    try {
      await QVoiceConfig.instance.setVoice(voiceId);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(voice: voiceId));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  void _showRatePicker() {
    final currentRate = _current.rate;
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.2,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in QVoiceConfig.rateOptions.entries)
                ListTile(
                  title: Text(entry.value, textAlign: TextAlign.center),
                  trailing: entry.key == currentRate
                      ? Icon(
                          Icons.check_circle,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  onTap: () => _selectRate(entry.key),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _selectRate(double rate) async {
    try {
      await QVoiceConfig.instance.setRate(rate);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(rate: rate));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }
}
