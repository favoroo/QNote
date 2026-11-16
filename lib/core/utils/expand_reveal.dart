import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';

/// 折叠区展开后，把它「刚好完整露出」所需的最小滚动偏移。
///
/// [target] 传折叠区整体（标题行 + 展开内容）：展开动画期间它的高度逐帧增长，
/// 逐帧调用本函数即可得到「此刻刚好完整露出」的位置，表现为跟随展开平滑下滑。
/// 与「直接滚到列表底部」不同：只下滑到展开内容的下边缘贴住视口下沿为止，
/// 既不会把展开内容后面的正文一起顶出视野，也不会在内容本来就能看全时白滚一段。
/// 内容比视口还高时改为把它顶部对齐视口顶部，让用户从头往下看。
///
/// 返回 null 表示无需滚动：当前已经看全，或内容整体在视口上方（不往回滚）。
double? expandedRevealOffset(RenderObject target, ScrollPosition position, {double bottomMargin = 12}) {
  final viewport = RenderAbstractViewport.maybeOf(target);
  if (viewport == null) {
    return null;
  }
  // getOffsetToReveal 的 alignment 是「目标自身」与「视口」的同比例点对齐：
  // 0.0 → 目标顶部贴视口顶部；1.0 → 目标底部贴视口底部（再加一点下边距，不贴死）
  final topAligned = viewport.getOffsetToReveal(target, 0.0).offset;
  final bottomAligned = viewport.getOffsetToReveal(target, 1.0).offset + bottomMargin;
  final desired = math
      .min(topAligned, bottomAligned)
      .clamp(position.minScrollExtent, position.maxScrollExtent)
      .toDouble();
  // 只向下滑：已经能看全、或内容在视口上方时保持原位，不打断用户当前阅读
  return desired > position.pixels + 0.5 ? desired : null;
}

/// 折叠区展开时跟随高度动画，把新展开的内容滚入视野。
///
/// 折叠区用 `AppCollapsible` 做 200ms 的高度过渡，目标节点的高度逐帧增长；
/// 这里在动画期间逐帧按当前高度算出「刚好完整露出」的位置并贴过去，
/// 用一个略长于展开动画的时间窗收尾，不依赖刷新率也不需要额外定时器。
class ExpandRevealFollower {
  ExpandRevealFollower(this.revealKey);

  /// 折叠区根部节点的 key（标题行 + 展开内容），须位于内层滚动视图之外
  final GlobalKey revealKey;

  /// 跟随窗口：默认展开动画 200ms，多留一档兜住动画落定后的补帧
  static final Duration _followWindow = AppDurations.normal + AppDurations.fast;

  /// 跟进令牌：收起或重新展开会作废上一轮，避免两段动画互相拉扯
  int _token = 0;

  /// 本轮跟随的起始帧时间戳；用帧时间而不是挂钟时间，测试与真实刷新率下都稳定
  Duration? _startedAt;

  /// 开始跟随一次展开；重复调用会接替上一轮
  void start() {
    final token = ++_token;
    _startedAt = null;

    void step() {
      if (token != _token) {
        return; // 已被新的展开/收起接管
      }
      final context = revealKey.currentContext;
      final renderObject = context?.findRenderObject();
      final position = context == null ? null : Scrollable.maybeOf(context)?.position;
      if (renderObject == null || position == null) {
        return; // 内容未挂载或不在滚动容器里，没有可跟随的对象
      }
      final offset = expandedRevealOffset(renderObject, position);
      // 用户已经接手拖动/惯性滚动时不再抢滚动权
      if (offset != null && !position.isScrollingNotifier.value) {
        position.jumpTo(offset);
      }
      final now = SchedulerBinding.instance.currentFrameTimeStamp;
      final startedAt = _startedAt ??= now;
      if (now - startedAt < _followWindow) {
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step());
  }

  /// 收起或销毁时停止跟随
  void cancel() => _token++;
}
