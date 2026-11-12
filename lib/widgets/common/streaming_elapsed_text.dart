import 'dart:async';

import 'package:flutter/material.dart';

/// 流式已用时计时文本：状态行尾部的「· 12s」递增计数。
///
/// 与 AnimatedEllipsis 搭配表达任务仍在进行；为运行级计时，
/// 阶段状态切换（思考中→执行中）不清零。开始 3 秒内不显示，
/// 避免快速完成的任务出现数字闪烁。AI 主页与小Q悬浮球共用。
class StreamingElapsedText extends StatefulWidget {
  /// 计时起点；为 null 时不渲染
  final DateTime? startedAt;

  /// 文字样式，缺省取主题 onSurfaceVariant 弱化色
  final TextStyle? style;

  const StreamingElapsedText({super.key, this.startedAt, this.style});

  @override
  State<StreamingElapsedText> createState() => _StreamingElapsedTextState();
}

class _StreamingElapsedTextState extends State<StreamingElapsedText> {
  Timer? _timer;

  /// 当前所在子树是否可见；TickerMode 关闭时暂停秒表，避免后台空转
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    // 先按可见启动；若挂载时就处于隐藏子树，紧随其后的 didChangeDependencies 会立刻停表
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode 变化会通知依赖者（切 tab、被路由覆盖等），据此成对暂停/恢复
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    _syncTicker();
  }

  @override
  void didUpdateWidget(StreamingElapsedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// 起点存在且可见时每秒自增刷新；起点被清空或子树隐藏即停表
  void _syncTicker() {
    if (widget.startedAt == null || !_visible) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format(Duration elapsed) {
    final seconds = elapsed.inSeconds;
    if (seconds < 60) return '$seconds s';
    final minutes = seconds ~/ 60;
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes m $rest s';
  }

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    if (startedAt == null) return const SizedBox.shrink();
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed.inSeconds < 3) return const SizedBox.shrink();
    final style = widget.style ?? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12);
    return Text('· ${_format(elapsed)}', style: style);
  }
}
