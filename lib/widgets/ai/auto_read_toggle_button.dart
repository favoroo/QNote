import 'dart:async';

import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 自动朗读开关按钮（纯图标，点一下即开/关）。
///
/// 放在小Q对话界面右上角，让「要不要把回复读出来」随手可达，
/// 不必进 设置 → 小Q语音 里找。状态与语音设置页共用 [QVoiceConfig] 同一真源
/// （app_configs 的 `q_voice`，随 WebDAV 云同步），任一处改动双向同步。
class AutoReadToggleButton extends StatefulWidget {
  const AutoReadToggleButton({super.key, this.iconSize = 20});

  /// 图标边长：与所在表头/操作栏的相邻按钮保持一致
  final double iconSize;

  @override
  State<AutoReadToggleButton> createState() => _AutoReadToggleButtonState();
}

class _AutoReadToggleButtonState extends State<AutoReadToggleButton> {
  /// 写库在途标记：连点会并发翻转同一开关，后完成的覆盖先完成的
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 冷启动时开关只存在数据库里，先按默认态渲染，拉回后由 autoReadState 纠正图标
    unawaited(_preloadConfig());
  }

  Future<void> _preloadConfig() async {
    try {
      await QVoiceConfig.instance.get();
    } catch (_) {
      // 读取失败保持默认（关闭）态，不弹提示打扰：点击时会再走一次带错误的写入路径
    }
  }

  Future<void> _toggle() async {
    if (_saving) return;
    _saving = true;
    try {
      await QVoiceConfig.instance.toggleAutoRead();
    } catch (e) {
      if (!mounted) return;
      // 开关状态未被改动，图标保持原样，失败必须报出来
      Toast.error(context, '自动朗读设置失败：$e');
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: QVoiceConfig.instance.autoReadState,
      builder: (context, enabled, _) {
        return IconButton(
          onPressed: _toggle,
          tooltip: enabled ? '自动朗读：已开启，点击关闭' : '自动朗读：已关闭，点击开启',
          // 关闭态用 volume_off 明示「现在不会读」，再配 primary 色区分开启态，
          // 比只调深浅更容易一眼扫出来
          icon: Icon(
            enabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            size: widget.iconSize,
          ),
          color: enabled ? scheme.primary : scheme.onSurfaceVariant,
        );
      },
    );
  }
}
