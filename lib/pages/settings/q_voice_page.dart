import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/core/tts/tts_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 小Q语音回复设置
///
/// 提供自动朗读开关、Edge 音色选择（带试听）与语速档位；
/// 在线音色依赖 Edge 语音服务，非 Edge 浏览器/无网络时自动降级为设备语音，
/// 试听失败会以 Toast 报出具体原因。
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

    // 试听失败此前只写进播放状态、界面上既没声音也没提示（与气泡按钮不同），
    // 这里对齐 Toast 报错，让"为什么没出声"可见
    ref.listen<TtsPlaybackState>(ttsPlaybackProvider, (prev, next) {
      final error = next.error;
      if (error != null && error.isNotEmpty) {
        Toast.error(context, '语音试听失败：$error');
      }
    });

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
                      _current.voice == QVoiceConfig.systemVoiceId
                          ? '系统语音'
                          : TtsService.voiceById(_current.voice).label,
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

  /// 音色选择弹窗：每行带试听按钮，选中不关闭弹窗并自动试播，由用户自行关闭
  void _showVoicePicker() {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        // 面板整体吃掉点击（opaque）：面板内空白处点按不会落到 modal barrier
        // 造成"点透"式误关闭
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: SafeArea(
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
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
                    // 弹窗挂在 root Navigator，页面的 setState 不会重建弹窗子树，
                    // 勾选态必须由弹窗自身的 sheetSetState 刷新
                    child: StatefulBuilder(
                      builder: (_, sheetSetState) => ListView(
                        shrinkWrap: true,
                        children: [
                          // 系统语音：设备自带引擎，离线可用，无网络依赖
                          ListTile(
                            leading: const _PreviewButton(
                              voiceId: QVoiceConfig.systemVoiceId,
                            ),
                            title: const Text('系统语音'),
                            subtitle: Text(
                              '设备自带 · 离线可用',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            trailing:
                                _current.voice == QVoiceConfig.systemVoiceId
                                    ? Icon(
                                        Icons.check_circle,
                                        color: theme.colorScheme.primary,
                                      )
                                    : null,
                            onTap: () => _selectVoice(
                              QVoiceConfig.systemVoiceId,
                              sheetSetState,
                            ),
                          ),
                          for (final voice in TtsService.builtinVoices)
                            ListTile(
                              leading: _PreviewButton(voiceId: voice.id),
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
                              onTap: () => _selectVoice(voice.id, sheetSetState),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      // 弹窗关闭时若试听还在播则停掉；messageId 限定 preview 前缀，
      // 不影响可能由其他入口触发的正文朗读
      final playback = ref.read(ttsPlaybackProvider);
      if (playback.messageId?.startsWith('preview_') == true) {
        ref.read(ttsPlaybackProvider.notifier).stop();
      }
    });
  }

  /// 选中音色：持久化后刷新弹窗勾选并自动试播；弹窗保持打开，由用户自行关闭
  Future<void> _selectVoice(String voiceId, StateSetter refreshSheet) async {
    try {
      await QVoiceConfig.instance.setVoice(voiceId);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(voice: voiceId));
      refreshSheet(() {});
      // 选中即试播：正在播这条就不重复触发，播别的音色时由播放器
      // 单通道逻辑自动切换
      final previewKey = _PreviewButton.keyOf(voiceId);
      final playback = ref.read(ttsPlaybackProvider);
      final isThisPlaying = playback.messageId == previewKey &&
          playback.status != TtsPlaybackStatus.idle;
      if (!isThisPlaying) {
        ref.read(ttsPlaybackProvider.notifier).speakMessage(
              previewKey,
              _PreviewButton.previewText,
              voiceOverride: voiceId,
            );
      }
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        // 面板整体吃掉点击，防空白处点透到 modal barrier 误关闭
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: SafeArea(
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
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
                      onTap: () => _selectRate(ctx, entry.key),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectRate(BuildContext sheetCtx, double rate) async {
    try {
      await QVoiceConfig.instance.setRate(rate);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(rate: rate));
      Navigator.of(sheetCtx).pop();
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }
}

/// 音色试听按钮：独立 ConsumerWidget 而非页面 State 方法，因为弹窗
/// 挂在 root Navigator 上，页面 State 的 ref.watch 依赖会随页面重建失效，
/// 弹窗内的合成中/播放中状态从此不再更新（转圈永不出现）
class _PreviewButton extends ConsumerWidget {
  const _PreviewButton({required this.voiceId});

  /// 固定示例句，选中音色的自动试播与按钮点播共用
  static const String previewText = '你好，我是小Q，很高兴认识你。';

  /// 试听在播放通道里的消息标识（关闭弹窗停止播放时按此前缀识别）
  static String keyOf(String voiceId) => 'preview_$voiceId';

  final String voiceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(ttsPlaybackProvider);
    final previewKey = keyOf(voiceId);
    final isPlaying = playback.messageId == previewKey &&
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
        notifier.speakMessage(previewKey, previewText, voiceOverride: voiceId);
      },
      // 合成需一次网络请求，转圈让"延迟"变成可见的加载而非卡住
      icon: AnimatedSwitcher(
        duration: AppDurations.fast,
        child: isBusy
            ? const SizedBox(
                key: ValueKey('busy'),
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                key: ValueKey(isPlaying),
              ),
      ),
    );
  }
}
