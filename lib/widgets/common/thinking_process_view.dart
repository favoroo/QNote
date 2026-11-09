import 'package:flutter/material.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
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

/// 思考过程展示：折叠态单行横向滚动展示最新思考，点击标题行展开全文
///
/// 视觉与交互参考 ZCode：默认只占一行，不打断对话阅读；展开后限高滚动、
/// 自动贴底跟随。用户手动展开过则流式结束不回落到单行，避免打断阅读。
class ThinkingProcessView extends StatefulWidget {
  /// 截至当前的完整思考文本（调用方累积）
  final String thought;

  /// 是否仍在流式输出：决定标签文案与「结束后自动收起到单行」
  final bool isStreaming;

  const ThinkingProcessView({
    super.key,
    required this.thought,
    this.isStreaming = false,
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
    final latest = latestThoughtLine(widget.thought);

    return AnimatedSize(
      duration: AppDurations.medium,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.18),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题行：点击展开/收起；折叠时右侧展示最新一行思考
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _toggle,
                child: Semantics(
                  button: true,
                  label: _expanded ? '收起思考过程' : '展开思考过程',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.psychology_outlined,
                          size: 15,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        _ThoughtBadge(
                          text: widget.isStreaming ? '思考中' : '思考过程',
                          theme: theme,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _expanded
                              ? const SizedBox.shrink()
                              : _LatestThoughtLine(
                                  text: latest,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: AppDurations.normal,
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
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
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                  child: ThoughtTailScrollView(
                    text: widget.thought,
                    maxHeight: 320,
                    padding: const EdgeInsets.all(10),
                    textStyle: TextStyle(
                      fontSize: 12,
                      height: 1.55,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                      fontStyle: FontStyle.italic,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「思考中 / 思考过程」小徽标
class _ThoughtBadge extends StatelessWidget {
  final String text;
  final ThemeData theme;

  const _ThoughtBadge({required this.text, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
          letterSpacing: 0.2,
        ),
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
    _scheduleTailScroll();
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
