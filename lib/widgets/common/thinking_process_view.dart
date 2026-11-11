import 'dart:async';

import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/widgets/common/thought_tail_scroll_view.dart';

/// 取思考文本中最新的一行（最后一个非空行）
///
/// 流式输出可能以换行结尾，直接取最后一段会得到空串；模型也常整段不换行，
/// 此时整段就是「最新一行」，由横向滚动把末尾露出来。
String latestThoughtLine(String thought) {
  final lines = thought.split('\n');
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isNotEmpty) {
      return line;
    }
  }
  return '';
}

/// 思考耗时文案（如「3 秒」「1 分 20 秒」）；无有效秒数返回空串
///
/// 秒数缺失时宁可不显示，也不用「0 秒」这类没有信息量的占位。
String thinkingDurationLabel(int? seconds) {
  if (seconds == null || seconds < 1) {
    return '';
  }
  if (seconds < 60) {
    return '$seconds 秒';
  }
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '$minutes 分' : '$minutes 分 $rest 秒';
}

/// 一段思考过程的展示：折叠态单行横向滚动展示最新思考，点击标题行展开全文
///
/// 视觉与交互对齐 ZCode：默认只占一行、不打断对话阅读；展开后限高滚动并自动
/// 贴底跟随。一段思考 = 一个实例，多轮 ReAct 的多段思考各自独立收放，
/// 用户能逐段回看，而不是只剩最后一段。
class ThinkingProcessView extends StatefulWidget {
  /// 截至当前的完整思考文本（调用方累积）
  final String thought;

  /// 是否仍在流式输出：决定标签文案、计时与「结束后自动收起到单行」
  final bool isStreaming;

  /// 已结束思考段的耗时（秒）；流式期间用 [startedAt] 现算
  final int? durationSeconds;

  /// 流式计时起点；为 null 时不显示耗时
  final DateTime? startedAt;

  /// 标题文案，默认「思考」
  final String label;

  const ThinkingProcessView({
    super.key,
    required this.thought,
    this.isStreaming = false,
    this.durationSeconds,
    this.startedAt,
    this.label = '思考',
  });

  @override
  State<ThinkingProcessView> createState() => _ThinkingProcessViewState();
}

class _ThinkingProcessViewState extends State<ThinkingProcessView> {
  bool _expanded = false;

  /// 用户手动展开/收起过：流式结束时保留用户的选择
  bool _userToggled = false;

  @override
  void didUpdateWidget(covariant ThinkingProcessView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 流式结束：自动回落到单行；用户手动展开过则保持展开
    if (oldWidget.isStreaming && !widget.isStreaming && !_userToggled) {
      _expanded = false;
    }
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      _userToggled = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final latest = latestThoughtLine(widget.thought);
    final durationText = widget.isStreaming
        ? ''
        : thinkingDurationLabel(widget.durationSeconds);

    return AnimatedSize(
      duration: AppDurations.medium,
      curve: AppCurves.emphasized,
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行：点击展开/收起；折叠时右侧展示最新一行思考
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggle,
              borderRadius: BorderRadius.circular(8),
              child: Semantics(
                button: true,
                label: _expanded ? '收起思考' : '展开思考',
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      _ThinkingGlyph(
                        isStreaming: widget.isStreaming,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (widget.isStreaming)
                        _StreamingThoughtClock(startedAt: widget.startedAt)
                      else if (durationText.isNotEmpty)
                        Text(
                          ' · $durationText',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.outline,
                          ),
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _expanded
                            ? const SizedBox.shrink()
                            : _LatestThoughtLine(
                                text: latest,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.75),
                                ),
                              ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: AppMotion.duration(context, AppDurations.normal),
                        curve: AppCurves.emphasized,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 展开态：完整思考过程，限高滚动并自动贴底
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2, bottom: 8),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.35,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
                child: ThoughtTailScrollView(
                  text: widget.thought,
                  maxHeight: 320,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  textStyle: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 思考图标：流式期间轻微呼吸，替代静态图标传达「仍在思考」
class _ThinkingGlyph extends StatefulWidget {
  final bool isStreaming;
  final Color color;

  const _ThinkingGlyph({required this.isStreaming, required this.color});

  @override
  State<_ThinkingGlyph> createState() => _ThinkingGlyphState();
}

class _ThinkingGlyphState extends State<_ThinkingGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _ThinkingGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming != widget.isStreaming) {
      _sync();
    }
  }

  void _sync() {
    if (widget.isStreaming) {
      _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.psychology_outlined, size: 15, color: widget.color);
    if (!widget.isStreaming) {
      return icon;
    }
    return FadeTransition(
      opacity: Tween(
        begin: 0.5,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: icon,
    );
  }
}

/// 流式思考的递增耗时（「 · 3 秒」），每秒自增
class _StreamingThoughtClock extends StatefulWidget {
  final DateTime? startedAt;

  const _StreamingThoughtClock({this.startedAt});

  @override
  State<_StreamingThoughtClock> createState() => _StreamingThoughtClockState();
}

class _StreamingThoughtClockState extends State<_StreamingThoughtClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _StreamingThoughtClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    if (widget.startedAt == null) {
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

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    if (startedAt == null) {
      return const SizedBox.shrink();
    }
    final label = thinkingDurationLabel(
      DateTime.now().difference(startedAt).inSeconds,
    );
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      ' · $label',
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// 折叠态的最新一行：横向滚动贴尾，左侧渐隐提示还有更早的思考
class _LatestThoughtLine extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _LatestThoughtLine({required this.text, this.style});

  @override
  State<_LatestThoughtLine> createState() => _LatestThoughtLineState();
}

class _LatestThoughtLineState extends State<_LatestThoughtLine> {
  final ScrollController _controller = ScrollController();

  /// 是否自动跟随到最右（最新）；用户向左拖离后暂停
  bool _follow = true;

  bool get _isNearTail =>
      !_controller.hasClients ||
      _controller.position.maxScrollExtent - _controller.offset < 2;

  @override
  void initState() {
    super.initState();
    // 首次挂载后贴到最新一行；后续文本变化由 didUpdateWidget 触发。
    _scheduleTailScroll();
  }

  @override
  void didUpdateWidget(covariant _LatestThoughtLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text && _follow) {
      _scheduleTailScroll();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 新思考到达后贴尾；post-frame 等待布局完成再读取滚动范围
  void _scheduleTailScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || !_follow) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 已滚离最左时左侧渐隐，提示前面还有更早的思考
    final showLeftFade = _controller.hasClients && _controller.offset > 2;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          if (notification.dragDetails != null) _follow = false;
          if (_isNearTail) _follow = true;
          setState(() {}); // 刷新左侧渐隐的可见性
        }
        return false;
      },
      child: ShaderMask(
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: showLeftFade
              ? const [Colors.transparent, Colors.white]
              : const [Colors.white, Colors.white],
          stops: showLeftFade ? const [0.0, 0.18] : null,
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            style: widget.style,
          ),
        ),
      ),
    );
  }
}
