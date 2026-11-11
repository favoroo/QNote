/// 悬浮小Q气泡的版式计算（纯函数，不依赖 Widget / MediaQuery）
///
/// 抽出来的原因：气泡尺寸、默认落点与贴边吸附都是「和别的悬浮控件抢同一块屏幕」
/// 的几何约束。时间线右下角压着「每日日记」与「智能提取」两个 44 圆钮，气泡如果
/// 只按底部导航栏算间距就会直接压在上面 —— 这类问题在没有真机的单测里看不出来，
/// 必须把「避让高度」写成可断言的不变量。
library;

import 'dart:math' as math;

import 'dart:ui' show Offset, Rect, Size;

/// 气泡直径。
///
/// 从 56 收到 48：它是常驻最小化态的入口，尺寸越大越容易压住页面右下角的
/// 功能按钮；48 仍是移动端舒适触控尺寸（≥44），且与小Q 头像的视觉比例更紧凑。
const double kQBubbleSize = 48;

/// 气泡贴边留白（左/右/上）。
const double kQBubbleEdgeMargin = 8;

/// 底部导航栏内容高度（与 `bottom_nav_bar.dart` 的 `_navBarContentHeight` 同值）。
const double kQNavBarContentHeight = 66;

/// 页面右下角悬浮操作按钮那一排的高度（时间线「智能提取」/「每日日记」为 44 圆钮）。
const double kQFloatingActionRowHeight = 44;

/// 按钮行与导航栏之间、按钮行与气泡之间的呼吸间距。
const double kQFloatingActionGap = 12;

/// 气泡默认落点距屏幕底部的总高度。
///
/// 组成：导航栏 66 + 按钮行 44 + 两段间距 12×2 + 额外 8 的视觉留白 = 142。
/// 关键是**必须越过按钮行**：气泡与智能提取按钮同贴右边缘，只要底部间距小于
/// 「按钮行顶部」就会叠在一起。
const double kQBubbleDefaultBottomGap = kQNavBarContentHeight + kQFloatingActionRowHeight + kQFloatingActionGap * 2 + 8;

/// 气泡默认落点（右下角、避开按钮行与导航栏）
Offset defaultQBubblePosition(Size size, {required double bottomInset, double rightMargin = 16}) {
  return Offset(
    size.width - kQBubbleSize - rightMargin,
    size.height - kQBubbleSize - kQBubbleDefaultBottomGap - bottomInset,
  );
}

/// 把气泡限制在可视区域内（顶部安全区之下、底部导航/键盘之上）
Offset clampQBubblePosition(Offset position, Size size, {required double topInset, required double bottomInset}) {
  const minX = kQBubbleEdgeMargin;
  final maxX = math.max(minX, size.width - kQBubbleSize - kQBubbleEdgeMargin);
  final minY = topInset + kQBubbleEdgeMargin;
  final maxY = math.max(minY, size.height - bottomInset - kQBubbleSize - kQBubbleEdgeMargin);
  return Offset(position.dx.clamp(minX, maxX), position.dy.clamp(minY, maxY));
}

/// 松手后磁吸到最近的左右边缘（只改 X，Y 保持用户拖到的位置）
Offset snapQBubbleX(Offset position, Size size) {
  const left = kQBubbleEdgeMargin;
  final right = math.max(left, size.width - kQBubbleSize - kQBubbleEdgeMargin);
  final snappedX = position.dx + kQBubbleSize / 2 < size.width / 2 ? left : right;
  return Offset(snappedX, position.dy);
}

/// 气泡占位矩形
Rect qBubbleRect(Offset position) => position & const Size(kQBubbleSize, kQBubbleSize);
