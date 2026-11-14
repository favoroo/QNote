import 'dart:math' as math;
import 'dart:ui' as ui show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 单日时间线正文的 Sliver 级幕布展开/收起容器。
///
/// 与在 `ListView` 里把 48 个半小时槽位分别包进 [AppCollapsible] 不同：
/// - 稳态已展开时（[sizeAnimation] 为 null）零开销直通子 Sliver，保持 [SliverList] 的按需懒加载；
/// - 展开/收起过渡期间仅使用 1 个裁剪层与 1 个透明层在视口可见高度内平滑推进，
///   子 `SliverList` 只构建随幕布前沿进入视口的少量节点，避免首帧同步构建整天 48 个节点与卡片。
class SliverDayCollapsible extends SingleChildRenderObjectWidget {
  const SliverDayCollapsible({
    super.key,
    required this.sizeAnimation,
    required this.opacityAnimation,
    required this.isExpanding,
    required Widget sliver,
  }) : super(child: sliver);

  /// 高度比例动画（0.0 -> 1.0）；为 null 表示稳态已展开，直接透传子 Sliver。
  final Animation<double>? sizeAnimation;

  /// 透明度动画（0.0 -> 1.0）；为 null 时保持完全不透明。
  final Animation<double>? opacityAnimation;

  /// 当前处于展开方向（true）还是收起方向（false）。
  final bool isExpanding;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderSliverDayCollapsible(
      sizeAnimation: sizeAnimation,
      opacityAnimation: opacityAnimation,
      isExpanding: isExpanding,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final sliver = renderObject as _RenderSliverDayCollapsible;
    sliver
      ..sizeAnimation = sizeAnimation
      ..opacityAnimation = opacityAnimation
      ..isExpanding = isExpanding;
  }
}

class _RenderSliverDayCollapsible extends RenderProxySliver {
  _RenderSliverDayCollapsible({
    required Animation<double>? sizeAnimation,
    required Animation<double>? opacityAnimation,
    required bool isExpanding,
  }) : _sizeAnimation = sizeAnimation,
       _opacityAnimation = opacityAnimation,
       _isExpanding = isExpanding;

  Animation<double>? _sizeAnimation;
  Animation<double>? _opacityAnimation;
  bool _isExpanding;

  /// 本次展开/收起过渡在视口内的目标最大高度（像素）。
  ///
  /// 一天 48 个节点至少 2304px，远超单屏高度；把动画范围锁定在分隔栏下方的可见视口内，
  /// 既能避免收起前半段把时间浪费在屏幕外，也能在展开途中中途反向时保持高度连续。
  double? _extentCap;

  /// 过渡期间上一次上报给父级的受限 `scrollExtent`，用于离屏收尾时的滚动位置补偿。
  double? _lastAnimatedScrollExtent;

  /// 展开途中用户主动向下滑入该天内容时置 true，提前解除高度上限以防滚动碰壁。
  bool _bypassCap = false;

  final LayerHandle<OpacityLayer> _opacityLayer = LayerHandle<OpacityLayer>();

  Animation<double>? get sizeAnimation => _sizeAnimation;
  set sizeAnimation(Animation<double>? value) {
    if (_sizeAnimation == value) {
      return;
    }
    if (attached) {
      _sizeAnimation?.removeListener(_handleSizeTick);
    }
    final wasNull = _sizeAnimation == null;
    _sizeAnimation = value;
    if (attached) {
      _sizeAnimation?.addListener(_handleSizeTick);
    }
    if (wasNull != (value == null)) {
      if (value != null) {
        _extentCap = null;
        _lastAnimatedScrollExtent = null;
        _bypassCap = false;
      } else {
        _bypassCap = false;
      }
      markNeedsCompositingBitsUpdate();
    }
    markNeedsLayout();
  }

  Animation<double>? get opacityAnimation => _opacityAnimation;
  set opacityAnimation(Animation<double>? value) {
    if (_opacityAnimation == value) {
      return;
    }
    if (attached) {
      _opacityAnimation?.removeListener(_handleOpacityTick);
    }
    _opacityAnimation = value;
    if (attached) {
      _opacityAnimation?.addListener(_handleOpacityTick);
    }
    markNeedsPaint();
  }

  bool get isExpanding => _isExpanding;
  set isExpanding(bool value) {
    if (_isExpanding == value) {
      return;
    }
    _isExpanding = value;
    if (!value && _bypassCap) {
      _bypassCap = false;
      markNeedsCompositingBitsUpdate();
    }
    if (value && _extentCap != null && _extentCap! <= 0.0) {
      _extentCap = null;
    }
    markNeedsLayout();
  }

  void _handleSizeTick() {
    markNeedsLayout();
  }

  void _handleOpacityTick() {
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sizeAnimation?.addListener(_handleSizeTick);
    _opacityAnimation?.addListener(_handleOpacityTick);
  }

  @override
  void detach() {
    _sizeAnimation?.removeListener(_handleSizeTick);
    _opacityAnimation?.removeListener(_handleOpacityTick);
    super.detach();
  }

  @override
  void dispose() {
    _opacityLayer.layer = null;
    super.dispose();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _sizeAnimation != null && !_bypassCap;

  double get _opacityValue {
    final anim = _opacityAnimation;
    if (anim == null) {
      return 1.0;
    }
    return clampDouble(anim.value, 0.0, 1.0);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      geometry = SliverGeometry.zero;
      return;
    }

    // 稳态已展开：零开销直通。
    if (_sizeAnimation == null) {
      final prevAnimatedExtent = _lastAnimatedScrollExtent;
      _lastAnimatedScrollExtent = null;
      _extentCap = null;
      _bypassCap = false;

      child.layout(constraints, parentUsesSize: true);
      final childGeo = child.geometry!;
      // 若展开动画结束时整天已经滚到视口顶部上方，补偿实际高度与临时上限的差值，防止下方内容跳动。
      if (prevAnimatedExtent != null &&
          constraints.scrollOffset > 0.0 &&
          constraints.scrollOffset >= prevAnimatedExtent) {
        final delta = childGeo.scrollExtent - prevAnimatedExtent;
        if (delta.abs() > precisionErrorTolerance) {
          geometry = SliverGeometry(scrollOffsetCorrection: delta);
          return;
        }
      }
      geometry = childGeo;
      return;
    }

    // 展开途中用户主动往下滑入该天内容：立即解除上限，避免滑到一半碰壁。
    if (_isExpanding && (_bypassCap || constraints.scrollOffset > 0.0)) {
      if (!_bypassCap) {
        _bypassCap = true;
        markNeedsCompositingBitsUpdate();
      }
      final prevAnimatedExtent = _lastAnimatedScrollExtent;
      _lastAnimatedScrollExtent = null;
      child.layout(constraints, parentUsesSize: true);
      final childGeo = child.geometry!;
      if (prevAnimatedExtent != null && constraints.scrollOffset >= prevAnimatedExtent) {
        final delta = childGeo.scrollExtent - prevAnimatedExtent;
        if (delta.abs() > precisionErrorTolerance) {
          geometry = SliverGeometry(scrollOffsetCorrection: delta);
          return;
        }
      }
      geometry = childGeo;
      return;
    }

    _extentCap ??= _isExpanding
        ? math.max(
            240.0,
            constraints.remainingPaintExtent > 0.0
                ? constraints.remainingPaintExtent
                : constraints.viewportMainAxisExtent,
          )
        : constraints.remainingPaintExtent;

    final factor = clampDouble(_sizeAnimation!.value, 0.0, 1.0);
    final visibleCap = _extentCap! * factor;
    if (visibleCap <= 0.0) {
      _lastAnimatedScrollExtent = 0.0;
      geometry = SliverGeometry.zero;
      return;
    }

    final remainingTarget = math.max(0.0, visibleCap - constraints.scrollOffset);
    if (remainingTarget <= 0.0) {
      _lastAnimatedScrollExtent = visibleCap;
      geometry = SliverGeometry(
        scrollExtent: visibleCap,
        maxPaintExtent: visibleCap,
        cacheExtent: calculateCacheOffset(constraints, from: 0.0, to: visibleCap),
      );
      return;
    }

    final childRemainingPaint = math.min(constraints.remainingPaintExtent, remainingTarget);
    // 动画期间只预构建可见前沿后约一个槽位（+48px），避免一次性把整天 48 个节点提前建完。
    final cacheTargetEnd = visibleCap + 48.0;
    final childScrollStart = constraints.scrollOffset + constraints.cacheOrigin;
    final childRemainingCache = math.min(
      constraints.remainingCacheExtent,
      math.max(childRemainingPaint, math.max(0.0, cacheTargetEnd - childScrollStart)),
    );

    child.layout(
      constraints.copyWith(remainingPaintExtent: childRemainingPaint, remainingCacheExtent: childRemainingCache),
      parentUsesSize: true,
    );
    final childGeo = child.geometry!;
    final availableExtent = math.max(childGeo.scrollExtent, constraints.scrollOffset + childGeo.paintExtent);
    final targetExtent = math.min(availableExtent, visibleCap);
    final paintExtent = calculatePaintOffset(constraints, from: 0.0, to: targetExtent);
    final cacheExtent = calculateCacheOffset(constraints, from: 0.0, to: targetExtent);

    _lastAnimatedScrollExtent = targetExtent;
    geometry = SliverGeometry(
      scrollExtent: targetExtent,
      paintExtent: paintExtent,
      layoutExtent: paintExtent,
      maxPaintExtent: math.max(paintExtent, targetExtent),
      hitTestExtent: paintExtent,
      cacheExtent: cacheExtent,
      hasVisualOverflow:
          childGeo.hasVisualOverflow ||
          targetExtent > constraints.scrollOffset + paintExtent ||
          availableExtent > targetExtent,
    );
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    final currentGeometry = geometry;
    if (child == null ||
        currentGeometry == null ||
        !currentGeometry.visible ||
        mainAxisPosition > currentGeometry.paintExtent) {
      return false;
    }
    return super.hitTestChildren(result, mainAxisPosition: mainAxisPosition, crossAxisPosition: crossAxisPosition);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final currentGeometry = geometry;
    if (child == null || currentGeometry == null || !currentGeometry.visible) {
      return;
    }
    if (_sizeAnimation != null && !_bypassCap && _opacityValue <= 0.0) {
      return;
    }
    visitor(child!);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final currentGeometry = geometry;
    if (child == null || currentGeometry == null || !currentGeometry.visible || currentGeometry.paintExtent <= 0.0) {
      layer = null;
      _opacityLayer.layer = null;
      return;
    }

    if (_sizeAnimation == null || _bypassCap) {
      layer = null;
      _opacityLayer.layer = null;
      context.paintChild(child!, offset);
      return;
    }

    final alpha = ui.Color.getAlphaFromOpacity(_opacityValue);
    if (alpha == 0) {
      layer = null;
      _opacityLayer.layer = null;
      return;
    }

    // 水平方向保留边距余量以免动画期间裁切卡片阴影，只严格裁切垂直幕布前沿。
    final clipRect = Rect.fromLTRB(-32.0, 0.0, constraints.crossAxisExtent + 32.0, currentGeometry.paintExtent);
    layer = context.pushClipRect(needsCompositing, offset, clipRect, (
      PaintingContext innerContext,
      Offset innerOffset,
    ) {
      if (alpha < 255) {
        _opacityLayer.layer = innerContext.pushOpacity(innerOffset, alpha, (
          PaintingContext opacityContext,
          Offset opacityOffset,
        ) {
          opacityContext.paintChild(child!, opacityOffset);
        }, oldLayer: _opacityLayer.layer);
      } else {
        _opacityLayer.layer = null;
        innerContext.paintChild(child!, innerOffset);
      }
    }, oldLayer: layer as ClipRectLayer?);
  }
}
