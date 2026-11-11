import 'package:flutter/foundation.dart';

/// 长按拾起后，指针位移超过该阈值才认为用户在「拖拽排序」。
///
/// 未超过阈值的抬手按「长按后原地松手」处理，由业务层弹操作菜单。
/// 取值略小于 [kTouchSlop]（18px）：既要吃掉手指的轻微抖动，又要足够灵敏，
/// 让用户轻推一下就能开始排序。
const double kReorderMoveThreshold = 8;

/// 该平台是否沿用「行尾手柄」这种鼠标友好的拖拽入口。
///
/// 桌面与 Web 以鼠标为主：按下手柄立刻能拖，比要求按住 500ms 更顺手；
/// 手机/平板以拇指为主：整行长按拾起更省事，不必瞄准行尾的小图标。
bool useDragHandleFor(TargetPlatform platform) {
  return platform == TargetPlatform.macOS || platform == TargetPlatform.windows || platform == TargetPlatform.linux;
}

/// 拖拽结束时，这次手势是否应被当作「长按」处理（用于弹操作菜单）。
///
/// 手势语义是「长按拾起 → 移动即排序，原地松手即菜单」，所以只有同时满足
/// 两点才算长按：
/// - [pointerMoved] 为 false：手指全程没移动过（拖出去再拖回原位也算移动）；
/// - [landedElsewhere] 为 false：没有落到别的行/别的落点上。
bool isLongPressRelease({required bool pointerMoved, required bool landedElsewhere}) {
  return !pointerMoved && !landedElsewhere;
}

/// 拖拽落点在目标行内的区域。
enum ReorderDropPosition {
  /// 插到目标行之前（与目标同级）
  before,

  /// 移入目标文件夹内部（仅文件夹行可用）
  inside,

  /// 插到目标行之后（与目标同级）
  after,
}

/// 文件夹行上下插入带所占行高的比例，中间剩余部分为「移入文件夹」。
///
/// 文件夹行本身只有约 44px 高，上下各留 22% 后仍有约 25px 的移入区，
/// 手指落在行中部时能稳定命中 inside，不会轻易被误判成前后插入。
const double kReorderInsideEdgeRatio = 0.22;

/// 根据指针在目标行内的纵向位置解析落点。
///
/// [allowsInside] 为 true 时（文件夹）中间区域返回 [ReorderDropPosition.inside]；
/// 为 false 时（笔记或不允许移入的文件夹）只按上下两半返回 before/after。
/// [localY] 会先裁剪到 `[0, rowHeight]`，避免拖拽浮层或滚动造成越界坐标抖动。
ReorderDropPosition resolveReorderDropPosition({
  required double localY,
  required double rowHeight,
  required bool allowsInside,
}) {
  if (rowHeight <= 0) {
    // 行高未知时按「插到后面」兜底，至少不会误判成移入文件夹
    return ReorderDropPosition.after;
  }

  final y = localY.clamp(0.0, rowHeight);
  if (!allowsInside) {
    return y < rowHeight * 0.5 ? ReorderDropPosition.before : ReorderDropPosition.after;
  }

  final edge = rowHeight * kReorderInsideEdgeRatio;
  if (y < edge) return ReorderDropPosition.before;
  if (y > rowHeight - edge) return ReorderDropPosition.after;
  return ReorderDropPosition.inside;
}
