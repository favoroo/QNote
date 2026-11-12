import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';

/// 记录板块「分段位置」动画的广播入口。
///
/// 值域 0（笔记）~ 1（待办）。笔记页与待办页各自持有一个
/// [RecordsSectionSwitcher]，切换时这两个实例都读同一个 [position]，
/// 于是交叉溶解中两页画出的滑块轨迹完全一致，不会出现「两个胶囊互相淡入淡出」的重影。
class RecordsSectionScope extends InheritedWidget {
  const RecordsSectionScope({super.key, required this.position, required super.child});

  /// 当前记录分段位置（0 = 笔记，1 = 待办），只在记录板块内切换时才有动画。
  final Animation<double> position;

  static Animation<double>? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<RecordsSectionScope>()?.position;
  }

  @override
  bool updateShouldNotify(RecordsSectionScope oldWidget) => !identical(position, oldWidget.position);
}

/// StatefulShellRoute 的分支容器：负责分支间的切换过渡。
///
/// 采用「单层溶解」而不是整屏交叉淡入：
/// - 栈序靠上（分支索引更大）的那一页做透明度动画，另一页保持不透明垫在下面。
///   这样任何时刻都只有一个 `saveLayer`，也不会先露出 Scaffold 底色造成闪白。
/// - 记录板块内部（笔记 ↔ 待办）切换时索引相邻、顶部栏结构相同，因此**不做位移**，
///   顶栏、滑块、右下加号在过渡中保持原位，只有内容在溶解。
/// - 其他分支切换保留约 3% 的方向性微位移，让「从右进入 / 向左退出」有方向感。
///
/// 每个分支都包 `RepaintBoundary`，透明度动画只更新合成层，不重绘整页子树。
class ShellBranchContainer extends StatefulWidget {
  const ShellBranchContainer({super.key, required this.currentIndex, required this.children});

  /// 当前激活分支索引（见 [ShellBranch]）。
  final int currentIndex;

  /// 各分支的 Navigator Widget，顺序与 [ShellBranch] 索引一致。
  final List<Widget> children;

  @override
  State<ShellBranchContainer> createState() => _ShellBranchContainerState();
}

class _ShellBranchContainerState extends State<ShellBranchContainer> with TickerProviderStateMixin {
  /// 记录板块内部切换（笔记 ↔ 待办）的时长：只做轻量溶解，比跨板块更短。
  static const Duration _recordsDuration = Duration(milliseconds: 200);

  /// 记录分段滑块的时长：略长于页面溶解，收尾更从容。
  static const Duration _sectionDuration = Duration(milliseconds: 260);

  /// 非记录板块切换的方向性微位移幅度（占屏宽比例）。
  static const double _slideExtent = 0.03;

  late final AnimationController _pageController;
  late final AnimationController _sectionController;

  /// 目标分支（过渡结束后的分支）。
  int _current = 0;

  /// 过渡中垫在下面、保持不透明的分支。
  int _backIndex = 0;

  /// 过渡中做透明度动画的分支（栈序靠上的一页）。
  int _frontIndex = 0;

  /// 动画面起始/结束不透明度。
  double _frontStart = 1;
  double _frontEnd = 1;

  /// 上一帧动画面实际不透明度，供动画中途被打断时续接，避免跳一下。
  double _frontOpacity = 1;

  /// 非记录切换时动画面的位移（相对自身宽高）。
  Offset _slideBegin = Offset.zero;
  Offset _slideEnd = Offset.zero;

  bool _animating = false;

  /// 记录分段位置：0 笔记 / 1 待办。
  double _sectionFrom = 0;
  double _sectionTo = 0;
  late Animation<double> _sectionAnimation;

  @override
  void initState() {
    super.initState();
    _current = widget.currentIndex;
    _backIndex = _current;
    _frontIndex = _current;
    _sectionFrom = _sectionValueOf(_current);
    _sectionTo = _sectionFrom;
    _pageController = AnimationController(vsync: this, duration: AppDurations.page)..value = 1;
    // 收尾时摘掉垫底分支与动画面包装，让树回到「只有当前分支可见」的稳态。
    _pageController.addStatusListener((status) {
      if (status == AnimationStatus.completed && _animating) {
        setState(() {
          _animating = false;
          _frontOpacity = 1;
        });
      }
    });
    _sectionController = AnimationController(vsync: this, duration: _sectionDuration)..value = 1;
    _sectionAnimation = _buildSectionAnimation();
  }

  static bool _isRecords(int index) => index == ShellBranch.notes || index == ShellBranch.todo;

  static double _sectionValueOf(int index) => index == ShellBranch.todo ? 1.0 : 0.0;

  Animation<double> _buildSectionAnimation() {
    return _sectionController.drive(
      Tween<double>(begin: _sectionFrom, end: _sectionTo).chain(CurveTween(curve: AppCurves.emphasized)),
    );
  }

  @override
  void didUpdateWidget(covariant ShellBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _startTransition(widget.currentIndex);
    }
  }

  void _startTransition(int to) {
    final from = _current;
    if (to == from) {
      return;
    }

    final recordsPair = _isRecords(from) && _isRecords(to);

    // 栈序靠上（索引更大）的一页负责透明度动画，另一页垫底保持不透明。
    final front = to > from ? to : from;
    final incoming = front == to;
    // 动画中途再次切换且动画面没变时，从它当前的不透明度续接，避免亮度跳变。
    final continueFromCurrent = _animating && front == _frontIndex;
    final startValue = continueFromCurrent ? _frontOpacity : (incoming ? 0.0 : 1.0);
    final endValue = incoming ? 1.0 : 0.0;

    _current = to;
    _frontIndex = front;
    _backIndex = incoming ? from : to;
    _frontStart = startValue;
    _frontEnd = endValue;

    final sign = to > from ? 1.0 : -1.0;
    if (recordsPair) {
      _slideBegin = Offset.zero;
      _slideEnd = Offset.zero;
    } else if (incoming) {
      _slideBegin = Offset(_slideExtent * sign, 0);
      _slideEnd = Offset.zero;
    } else {
      _slideBegin = Offset.zero;
      _slideEnd = Offset(-_slideExtent * sign, 0);
    }

    if (recordsPair) {
      _sectionFrom = _sectionValueOf(from);
      _sectionTo = _sectionValueOf(to);
    } else {
      final value = _isRecords(to) ? _sectionValueOf(to) : _sectionTo;
      _sectionFrom = value;
      _sectionTo = value;
    }
    _sectionAnimation = _buildSectionAnimation();

    if (MediaQuery.disableAnimationsOf(context)) {
      _animating = false;
      _frontOpacity = 1;
      _pageController.value = 1;
      _sectionController.value = 1;
      return;
    }

    _animating = true;
    _pageController.duration = recordsPair ? _recordsDuration : AppDurations.page;
    _sectionController.duration = _sectionDuration;
    _pageController.forward(from: 0);
    _sectionController.forward(from: 0);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _sectionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const curve = AppCurves.emphasized;
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        final raw = _animating ? _pageController.value : 1.0;
        final eased = curve.transform(raw);
        final frontOpacity = _animating ? (_frontStart + (_frontEnd - _frontStart) * eased).clamp(0.0, 1.0) : 1.0;
        _frontOpacity = frontOpacity;
        final slide = _animating ? Offset.lerp(_slideBegin, _slideEnd, eased)! : Offset.zero;

        final children = <Widget>[];
        for (var i = 0; i < widget.children.length; i++) {
          children.add(_wrapBranch(i, frontOpacity, slide));
        }

        return RecordsSectionScope(
          position: _sectionAnimation,
          child: Stack(fit: StackFit.expand, children: children),
        );
      },
    );
  }

  Widget _wrapBranch(int index, double frontOpacity, Offset slide) {
    final isCurrent = index == _current;
    final isFront = _animating && index == _frontIndex;
    final isBack = _animating && index == _backIndex;
    final visible = isFront || isBack || (!_animating && isCurrent);

    // 透明度/位移只施加在动画面；其他分支恒为 1 / 零位移。
    final opacity = isFront ? frontOpacity : 1.0;
    final translation = isFront ? slide : Offset.zero;

    // 包装链在所有分支、所有帧都保持同一形态：一旦结构随可见性增减节点，
    // Flutter 匹配不到 Element 就会整棵重建分支子树，滚动位置、展开态等局部状态会丢。
    return IgnorePointer(
      // 过渡期间整体不响应点击，避免在移动中的页面上误触。
      ignoring: !isCurrent || _animating,
      child: TickerMode(
        enabled: isCurrent,
        child: Offstage(
          offstage: !visible,
          child: RepaintBoundary(
            child: _BranchPresentation(opacity: opacity, translation: translation, child: widget.children[index]),
          ),
        ),
      ),
    );
  }
}

/// 分支的「透明度 + 相对位移」呈现层。
///
/// 之所以自绘 RenderObject 而不是组合 [Opacity]/[FractionalTranslation]：
/// 后两者在恒等值（透明度 1、位移 0）时仍会引入额外图层，而这里恒等时直接绘制、
/// 只有动画时才推入图层；这样包装链可以恒定不变，既不会丢分支状态也没有常驻开销。
class _BranchPresentation extends SingleChildRenderObjectWidget {
  const _BranchPresentation({required this.opacity, required this.translation, required super.child});

  /// 0~1，1 表示完全不透明。
  final double opacity;

  /// 相对自身宽高的位移（如 (0.03, 0) 表示右移 3% 宽度）。
  final Offset translation;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderBranchPresentation(opacity: opacity, translation: translation);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderBranchPresentation renderObject) {
    renderObject
      ..opacity = opacity
      ..translation = translation;
  }
}

class _RenderBranchPresentation extends RenderProxyBox {
  _RenderBranchPresentation({required double opacity, required Offset translation})
    : _opacity = opacity,
      _translation = translation;

  double _opacity;

  set opacity(double value) {
    if (value == _opacity) return;
    _opacity = value.clamp(0.0, 1.0);
    markNeedsPaint();
  }

  Offset _translation;

  set translation(Offset value) {
    if (value == _translation) return;
    _translation = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;

    final hasOpacity = _opacity < 1.0;
    final hasTranslation = _translation != Offset.zero;

    // 恒等态走最朴素的绘制路径，不产生任何图层。
    if (!hasOpacity && !hasTranslation) {
      super.paint(context, offset);
      return;
    }

    if (!hasTranslation) {
      context.pushOpacity(offset, (_opacity * 255).round(), (context, offset) => super.paint(context, offset));
      return;
    }

    final dx = _translation.dx * size.width;
    final dy = _translation.dy * size.height;
    final transform = Matrix4.translationValues(dx, dy, 0);
    if (!hasOpacity) {
      context.pushTransform(false, offset, transform, (context, offset) => super.paint(context, offset));
      return;
    }
    context.pushOpacity(offset, (_opacity * 255).round(), (context, offset) {
      context.pushTransform(true, offset, transform, (context, offset) => super.paint(context, offset));
    });
  }
}
