import 'dart:async';

import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/utils/chat_timeline.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
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
/// 复用纯逻辑层 [formatWorkflowDuration]，保持时间线与思考行口径一致。
String thinkingDurationLabel(int? seconds) => formatWorkflowDuration(seconds);

/// 一段思考过程的展示：折叠态单行横向滚动展示最新思考，点击标题行展开全文
///
/// 视觉与交互对齐 ZCode：默认只占一行、不打断对话阅读；展开后限高滚动并自动
/// 贴底跟随。支持非受控（组件自管）与受控（由外层按 turnKey 跨流式保留状态）两种模式。
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

  /// 受控展开状态；传入非 null 值时交由调用方记忆（如跨流式保留展开态）
  final bool? expanded;

  /// 受控模式下的展开切换回调
  final ValueChanged<bool>? onExpandedChanged;

  /// 紧凑模式：用于工作流展开列表或悬浮小Q面板内，收紧间距与最大高度
  final bool compact;

  const ThinkingProcessView({
    super.key,
    required this.thought,
    this.isStreaming = false,
    this.durationSeconds,
    this.startedAt,
    this.label = '思考',
    this.expanded,
    this.onExpandedChanged,
    this.compact = false,
  });

  @override
  State<ThinkingProcessView> createState() => _ThinkingProcessViewState();
}

class _ThinkingProcessViewState extends State<ThinkingProcessView> {
  bool _internalExpanded = false;

  /// 用户手动展开/收起过：流式结束时保留用户的选择
  bool _userToggled = false;

  bool get _isExpanded => widget.expanded ?? _internalExpanded;

  @override
  void didUpdateWidget(covariant ThinkingProcessView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 流式结束：自动回落到单行；用户手动展开过则保持展开
    if (widget.expanded == null && oldWidget.isStreaming && !widget.isStreaming && !_userToggled) {
      _internalExpanded = false;
    }
  }

  void _toggle() {
    final next = !_isExpanded;
    if (widget.onExpandedChanged != null) {
      widget.onExpandedChanged!(next);
      return;
    }
    setState(() {
      _internalExpanded = next;
      _userToggled = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final latest = latestThoughtLine(widget.thought);
    final durationText = widget.isStreaming ? '' : thinkingDurationLabel(widget.durationSeconds);
    final expanded = _isExpanded;

    // 外层直接用普通 Column，主体交给 AppCollapsible 与标题箭头同频（normal 档），
    // 收起时能保留完整思考区播放退场而不会只剩一块白底在缩高度。
    return Column(
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
              label: expanded ? '收起思考' : '展开思考',
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.compact ? 2 : 4, vertical: widget.compact ? 3 : 5),
                child: Row(
                  children: [
                    ThinkingBreathingGlyph(isStreaming: widget.isStreaming, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 7),
                    Text(
                      widget.label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colorScheme.onSurfaceVariant),
                    ),
                    if (widget.isStreaming)
                      StreamingThoughtClock(startedAt: widget.startedAt)
                    else if (durationText.isNotEmpty)
                      Text(' · $durationText', style: TextStyle(fontSize: 12, color: colorScheme.outline)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppMotion.switcher(
                        context: context,
                        scale: false,
                        child: expanded
                            ? const SizedBox.shrink(key: ValueKey('thought_latest_empty'))
                            : KeyedSubtree(
                                key: const ValueKey('thought_latest_line'),
                                child: RollingSingleLineText(
                                  text: latest,
                                  style: TextStyle(
                                    fontSize: 12,
                                    // 折叠态是正文之外最常被扫读的一行，透明度太低
                                    // 会和背景糊成一片，看起来像空白
                                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: AppMotion.duration(context, AppDurations.normal),
                      curve: AppCurves.emphasized,
                      child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 展开态：完整思考过程，限高滚动并自动贴底
        AppCollapsible(
          expanded: expanded,
          rise: 0,
          child: expanded
              ? Padding(
                  padding: EdgeInsets.only(left: widget.compact ? 18 : 26, top: 2, bottom: widget.compact ? 4 : 8),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.35)),
                    ),
                    child: ThoughtTailScrollView(
                      text: widget.thought,
                      maxHeight: widget.compact ? 200 : 320,
                      // 流式时贴底看最新思考；已结束的段落从开头展示，方便回看
                      autoFollow: widget.isStreaming,
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      textStyle: TextStyle(fontSize: 12, height: 1.6, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 思考/工作流呼吸图标：流式期间轻微呼吸，替代静态图标传达「仍在推进」
class ThinkingBreathingGlyph extends StatefulWidget {
  final bool isStreaming;
  final Color color;
  final IconData icon;
  final double size;

  const ThinkingBreathingGlyph({
    super.key,
    required this.isStreaming,
    required this.color,
    this.icon = Icons.psychology_outlined,
    this.size = 15,
  });

  @override
  State<ThinkingBreathingGlyph> createState() => _ThinkingBreathingGlyphState();
}

class _ThinkingBreathingGlyphState extends State<ThinkingBreathingGlyph> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// 系统「减弱动态效果」：呼吸循环停转，避免无意义地持续占着 ticker
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = AppMotion.reduce(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _sync();
    }
  }

  @override
  void didUpdateWidget(covariant ThinkingBreathingGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming != widget.isStreaming) {
      _sync();
    }
  }

  void _sync() {
    if (widget.isStreaming && !_reduceMotion) {
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
    final icon = Icon(widget.icon, size: widget.size, color: widget.color);
    if (!widget.isStreaming || _reduceMotion) {
      return icon;
    }
    return FadeTransition(
      opacity: Tween(begin: 0.5, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: AppCurves.standard)),
      child: icon,
    );
  }
}

/// 流式思考的递增耗时（「 · 3 秒」），每秒自增
class StreamingThoughtClock extends StatefulWidget {
  final DateTime? startedAt;

  const StreamingThoughtClock({super.key, this.startedAt});

  @override
  State<StreamingThoughtClock> createState() => _StreamingThoughtClockState();
}

class _StreamingThoughtClockState extends State<StreamingThoughtClock> {
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
  void didUpdateWidget(covariant StreamingThoughtClock oldWidget) {
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

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    if (startedAt == null) {
      return const SizedBox.shrink();
    }
    final label = thinkingDurationLabel(DateTime.now().difference(startedAt).inSeconds);
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(' · $label', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline));
  }
}

/// 折叠态的单行横向滚动文本：贴尾跟随，左侧渐隐提示还有更早内容
class RollingSingleLineText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const RollingSingleLineText({super.key, required this.text, this.style});

  @override
  State<RollingSingleLineText> createState() => _RollingSingleLineTextState();
}

class _RollingSingleLineTextState extends State<RollingSingleLineText> {
  final ScrollController _controller = ScrollController();

  /// 是否自动跟随到最右（最新）；用户向左拖离后暂停
  bool _follow = true;

  /// 上次构建时的左侧渐隐状态，仅在可见性变化时触发重建
  bool _showLeftFade = false;

  bool get _isNearTail => !_controller.hasClients || _controller.position.maxScrollExtent - _controller.offset < 2;

  @override
  void initState() {
    super.initState();
    // 首次挂载后贴到最新一行；后续文本变化由 didUpdateWidget 触发。
    _scheduleTailScroll();
  }

  @override
  void didUpdateWidget(covariant RollingSingleLineText oldWidget) {
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

  /// 拖动期间只暂停跟随，松手后停在尾部附近才恢复；
  /// 若在拖动中途按 `_isNearTail` 恢复，贴尾会立刻把用户拖回最右。
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _follow = false;
    } else if (notification is ScrollEndNotification) {
      _follow = _isNearTail;
    }
    final showLeftFade = _controller.hasClients && _controller.offset > 2;
    if (showLeftFade != _showLeftFade) {
      _showLeftFade = showLeftFade;
      setState(() {}); // 刷新左侧渐隐的可见性
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ShaderMask(
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          // 只在最左侧留一小段渐隐提示还有更早的内容：
          // 以前 18% 的渐隐宽度会把开头半句完全吃掉，看起来像一大段空白
          colors: _showLeftFade
              ? [Colors.white.withValues(alpha: 0.15), Colors.white]
              : const [Colors.white, Colors.white],
          stops: _showLeftFade ? const [0.0, 0.05] : null,
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: Text(widget.text, maxLines: 1, softWrap: false, style: widget.style),
        ),
      ),
    );
  }
}
