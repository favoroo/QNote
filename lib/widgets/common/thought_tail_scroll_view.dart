import 'package:flutter/material.dart';

/// 思考过程实时尾随视图：限高滚动展示流式思考文本，新内容自动贴底跟随
/// 减少等待体感；用户拖离底部后暂停跟随，滚回底部附近自动恢复，
/// 已滚离顶部时顶部渐隐提示上方还有内容。
///
/// AI 主页面「思考中」状态卡与小Q悬浮球面板的等待态共用
class ThoughtTailScrollView extends StatefulWidget {
  /// 完整的思考文本（调用方累积，组件内只负责尾随滚动展示）
  final String text;

  /// 滚动区最大高度，内容不足时自然收缩
  final double maxHeight;

  /// 思考文本样式（斜体弱化色由调用方决定）
  final TextStyle? textStyle;

  /// 滚动区内边距
  final EdgeInsetsGeometry padding;

  const ThoughtTailScrollView({
    super.key,
    required this.text,
    this.maxHeight = 96,
    this.textStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  });

  @override
  State<ThoughtTailScrollView> createState() => _ThoughtTailScrollViewState();
}

class _ThoughtTailScrollViewState extends State<ThoughtTailScrollView> {
  final ScrollController _controller = ScrollController();

  /// 是否自动跟随滚动到底部；用户拖离底部后暂停
  bool _follow = true;

  bool get _isNearBottom =>
      !_controller.hasClients ||
      _controller.position.maxScrollExtent - _controller.offset < 24;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 新思考内容到达后贴底；post-frame 等待布局完成再读取滚动范围
  void _scheduleFollowScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || !_follow) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleFollowScroll();
    // 已滚离顶部时顶部渐隐，提示上方还有思考内容
    final showTopFade = _controller.hasClients && _controller.offset > 2;
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: showTopFade
            ? const [Colors.transparent, Colors.white]
            : const [Colors.white, Colors.white],
        stops: showTopFade ? const [0.0, 0.16] : null,
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              // 用户拖动即暂停跟随；拖动后重新滚回底部附近则自动恢复
              if (notification.dragDetails != null) _follow = false;
              setState(() {}); // 刷新顶部渐隐的可见性
            }
            if (_isNearBottom) _follow = true;
            return false;
          },
          child: SingleChildScrollView(
            controller: _controller,
            padding: widget.padding,
            child: Text(
              widget.text,
              style: widget.textStyle,
            ),
          ),
        ),
      ),
    );
  }
}
