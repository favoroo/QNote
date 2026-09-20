import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/core/tts/tts_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 语速弹窗行首/行尾的常驻占位宽度（与 check_circle 同宽）。
///
/// 两侧等宽占位，档位名才居中；且勾选图标出现或消失时标题可用宽度不变，
/// 选中前后文字不会左右挪位。
const double _kRateSlotWidth = 24;

/// 试听在播放通道里的消息标识前缀（关闭弹窗时按此前缀识别并停播，
/// 不会误伤正文朗读）
const String _previewKeyPrefix = 'preview_';

/// 音色试听标识
String _voicePreviewKey(String voiceId) => '$_previewKeyPrefix$voiceId';

/// 语速档位试听标识：不带音色，音色变化时同一档位仍是同一个试听任务
String _ratePreviewKey(double rate) => '${_previewKeyPrefix}rate_$rate';

/// 小Q语音回复设置
///
/// 提供自动朗读开关、Edge 音色选择与语速档位；两个选择弹窗都「选中即试播且不收起」，
/// 方便连续试听对比。在线音色依赖 Edge 语音服务，非 Edge 浏览器/无网络时自动降级为
/// 设备语音，试听失败会以 Toast 报出具体原因。
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
          // 开关值直接取自配置真源的实时视图：小Q对话界面右上角的图标按钮也能改这个值，
          // 只听本地副本会导致这边显示滞后
          child: ValueListenableBuilder<bool>(
            valueListenable: QVoiceConfig.instance.autoReadState,
            builder: (context, autoRead, _) => SwitchListTile(
              value: autoRead,
              onChanged: _saveAutoRead,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text('自动朗读回复', style: theme.textTheme.bodyLarge),
              subtitle: Text(
                '小Q回复完成后用语音读出，可在小Q对话界面右上角快速切换',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
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
            child: _SheetPanel(
              title: '选择音色',
              // 弹窗挂在 root Navigator，页面的 setState 不会重建弹窗子树，
              // 勾选态必须由弹窗自身的 sheetSetState 刷新
              child: Flexible(
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
                        trailing: _current.voice == QVoiceConfig.systemVoiceId
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
            ),
          ),
        );
      },
    ).whenComplete(_stopPreviewIfPlaying);
  }

  /// 弹窗关闭时若试听还在播则停掉；messageId 限定 preview 前缀，
  /// 不影响可能由其他入口触发的正文朗读
  void _stopPreviewIfPlaying() {
    final playback = ref.read(ttsPlaybackProvider);
    if (playback.messageId?.startsWith(_previewKeyPrefix) == true) {
      ref.read(ttsPlaybackProvider.notifier).stop();
    }
  }

  /// 选中音色：持久化后刷新弹窗勾选并自动试播；弹窗保持打开，由用户自行关闭
  Future<void> _selectVoice(String voiceId, StateSetter refreshSheet) async {
    try {
      await QVoiceConfig.instance.setVoice(voiceId);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(voice: voiceId));
      refreshSheet(() {});
      _preview(_voicePreviewKey(voiceId), voiceOverride: voiceId);
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  /// 选中语速：持久化后刷新弹窗勾选并自动试播；弹窗保持打开，由用户自行关闭
  ///
  /// 语速只有 0.8/1.0/1.2 三档，光看文字难以预期效果，因此选中即试播，
  /// 且不像旧版那样选完就收起弹窗——用户需要连续试听对比。
  Future<void> _selectRate(double rate, StateSetter refreshSheet) async {
    try {
      await QVoiceConfig.instance.setRate(rate);
      if (!mounted) return;
      setState(() => _settings = _current.copyWith(rate: rate));
      refreshSheet(() {});
      _preview(_ratePreviewKey(rate), rateOverride: rate);
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  /// 试播固定示例句：正在播这一条就停下（再点一次即重播），播别的试听时
  /// 由播放器单通道逻辑自动切换
  void _preview(
    String previewKey, {
    String? voiceOverride,
    double? rateOverride,
  }) {
    final notifier = ref.read(ttsPlaybackProvider.notifier);
    final playback = ref.read(ttsPlaybackProvider);
    if (playback.messageId == previewKey &&
        playback.status != TtsPlaybackStatus.idle) {
      notifier.stop();
      return;
    }
    notifier.speakMessage(
      previewKey,
      _PreviewButton.previewText,
      voiceOverride: voiceOverride,
      rateOverride: rateOverride,
    );
  }

  /// 语速选择弹窗：档位名居中，选中不关闭弹窗并自动试播，由用户自行关闭
  void _showRatePicker() {
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
            child: _SheetPanel(
              title: '选择语速',
              // 勾选态由弹窗自身的 sheetSetState 刷新（同音色弹窗，
              // 弹窗挂在 root Navigator，页面的 setState 不会重建它）
              child: StatefulBuilder(
                builder: (_, sheetSetState) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in QVoiceConfig.rateOptions.entries)
                      ListTile(
                        // leading 与 trailing 等宽常驻：勾选图标出现或消失时
                        // 标题可用宽度不变，档位名就不会左右挪位
                        leading: const SizedBox(
                          width: _kRateSlotWidth,
                          height: _kRateSlotWidth,
                        ),
                        titleAlignment: ListTileTitleAlignment.center,
                        title: Text(entry.value, textAlign: TextAlign.center),
                        subtitle: Text(
                          '${entry.key} 倍速',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: SizedBox(
                          width: _kRateSlotWidth,
                          height: _kRateSlotWidth,
                          child: entry.key == _current.rate
                              ? Icon(
                                  Icons.check_circle,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                        ),
                        onTap: () => _selectRate(entry.key, sheetSetState),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(_stopPreviewIfPlaying);
  }
}

/// 底部弹窗面板：拖拽条 + 标题 + 内容，音色/语速两个弹窗共用
///
/// 底色必须由 Material 自身承担而不是外层套带颜色的 Container：ListTile 的水波纹
/// 画在最近的 Material 上，Container 底色会把涟漪盖在下面（debug 下直接断言报错）。
class _SheetPanel extends StatelessWidget {
  const _SheetPanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
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
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

/// 音色试听按钮：独立 ConsumerWidget 而非页面 State 方法，因为弹窗挂在 root
/// Navigator 上，页面 State 的 ref.watch 依赖会随页面重建失效，弹窗内的
/// 合成中/播放中状态从此不再更新（转圈永不出现）
class _PreviewButton extends ConsumerWidget {
  const _PreviewButton({required this.voiceId});

  /// 固定示例句，音色/语速弹窗的自动试播与按钮点播共用
  static const String previewText = '你好，我是小Q，很高兴认识你。';

  final String voiceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previewKey = _voicePreviewKey(voiceId);
    final playback = ref.watch(ttsPlaybackProvider);
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
        notifier.speakMessage(
          previewKey,
          previewText,
          voiceOverride: voiceId,
        );
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
