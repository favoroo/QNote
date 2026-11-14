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

  /// 是否自动贴底跟随新内容
  ///
  /// 流式思考需要一直看到最新一句；已结束的思考段展开时应从开头阅读，
  /// 否则一打开就停在末尾，用户得自己往回翻。
  final bool autoFollow;

  const ThoughtTailScrollView({
    super.key,
    required this.text,
    this.maxHeight = 96,
    this.textStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    this.autoFollow = true,
  });

  @override
  State<ThoughtTailScrollView> createState() => _ThoughtTailScrollViewState();
}

class _ThoughtTailScrollViewState extends State<ThoughtTailScrollView> {
  final ScrollController _controller = ScrollController();

  /// 是否自动跟随滚动到底部；用户拖离底部后暂停
  bool _follow = true;

  /// 上次构建时的顶部渐隐状态，仅在可见性变化时触发重建
  bool _showTopFade = false;

  bool get _isNearBottom => !_controller.hasClients || _controller.position.maxScrollExtent - _controller.offset < 24;

  @override
  void initState() {
    super.initState();
    _follow = widget.autoFollow;
    if (_follow) {
      _scheduleFollowScroll();
    }
  }

  @override
  void didUpdateWidget(covariant ThoughtTailScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有文本真正增长才贴底。以前每次 build 都调度贴底，拖动过程中下一帧
    // 就会把偏移量拽回 maxScrollExtent，思考区看起来完全滑不动。
    if (oldWidget.text != widget.text) {
      _scheduleFollowScroll();
    }
    // 流式结束（autoFollow 关闭）后不再贴底，保留用户当前阅读位置
    if (oldWidget.autoFollow != widget.autoFollow) {
      _follow = widget.autoFollow;
      if (_follow) {
        _scheduleFollowScroll();
      }
    }
  }

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

  /// 滚动通知：拖动期间绝不能恢复跟随，否则每帧都会被贴底打断；
  /// 只有松手后仍停在底部附近才恢复自动跟随。
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _follow = false;
    } else if (notification is ScrollEndNotification) {
      _follow = _isNearBottom;
    }
    // 顶部渐隐只在状态切换时重建，滚动过程中不逐帧 setState
    final showTopFade = _controller.hasClients && _controller.offset > 2;
    if (showTopFade != _showTopFade) {
      _showTopFade = showTopFade;
      setState(() {});
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 已滚离顶部时顶部渐隐，提示上方还有思考内容
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: _showTopFade ? const [Colors.transparent, Colors.white] : const [Colors.white, Colors.white],
        stops: _showTopFade ? const [0.0, 0.16] : null,
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: SingleChildScrollView(
            controller: _controller,
            padding: widget.padding,
            child: Text(widget.text, style: widget.textStyle),
          ),
        ),
      ),
    );
  }
}
