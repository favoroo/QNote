import 'package:flutter/material.dart';

/// 小Q 专属单体图标（轻量无圆形底座）。
///
/// 适用于导航栏、操作菜单（ActionMenu）、对话框头部的 Icon 场景。
class QIcon extends StatelessWidget {
  final double size;
  final Color? color;
  final Color? screenColor;
  final Color? eyeColor;

  const QIcon({
    super.key,
    this.size = 20,
    this.color,
    this.screenColor,
    this.eyeColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.primary;
    final effectiveEyeColor = eyeColor ?? theme.colorScheme.surface;
    final effectiveScreenColor = screenColor ?? effectiveColor;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        size: Size(size, size),
        painter: _QRobotPainter(
          bodyColor: effectiveColor,
          innerColor: effectiveEyeColor,
          screenColor: effectiveScreenColor,
        ),
      ),
    );
  }
}

/// 小Q 专属机器人头像 / 图标组件。
///
/// 严格依据小Q专属机器人视觉几何规范（天线圆球+天线杆、圆角头盔、内衬环形外框、数码屏幕与双胶囊眼睛）绘制。
/// 可自适应任意尺寸（小至 14px 图标，大至 80px+ 头像），支持自定义主色（机器人机身）与副色（内衬/眼睛）。
class QAvatar extends StatelessWidget {
  /// 图标/头像尺寸（宽和高相同）
  final double size;

  /// 机器人主色（机身、天线），默认为当前主题的 primary 色
  final Color? color;

  /// 内部屏幕颜色（默认等于主色）
  final Color? screenColor;

  /// 屏幕与眼睛的高亮/背景色（内圈高亮框和眼睛），默认根据机身颜色自适应（浅色底或白色/surface）
  final Color? eyeColor;

  /// 是否包含圆形背景底座
  final bool withBackground;

  /// 背景底座颜色（仅当 withBackground = true 时生效）
  final Color? backgroundColor;

  /// 内边距（仅当 withBackground = true 时起作用）
  final EdgeInsetsGeometry padding;

  const QAvatar({
    super.key,
    this.size = 24,
    this.color,
    this.screenColor,
    this.eyeColor,
    this.withBackground = false,
    this.backgroundColor,
    this.padding = const EdgeInsets.all(4),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.primary;
    final effectiveEyeColor = eyeColor ??
        (withBackground
            ? (backgroundColor ?? theme.colorScheme.surface)
            : theme.colorScheme.surface);
    final effectiveScreenColor = screenColor ?? effectiveColor;

    final iconWidget = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        size: Size(size, size),
        painter: _QRobotPainter(
          bodyColor: effectiveColor,
          innerColor: effectiveEyeColor,
          screenColor: effectiveScreenColor,
        ),
      ),
    );

    if (!withBackground) {
      return iconWidget;
    }

    final effectiveBg = backgroundColor ?? theme.colorScheme.primary.withValues(alpha: 0.15);

    return Container(
      width: size,
      height: size,
      padding: padding,
      decoration: BoxDecoration(
        color: effectiveBg,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: SizedBox(
          width: size * 0.64,
          height: size * 0.64,
          child: CustomPaint(
            size: Size(size * 0.64, size * 0.64),
            painter: _QRobotPainter(
              bodyColor: effectiveColor,
              innerColor: effectiveEyeColor,
              screenColor: effectiveScreenColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 小Q 专属矢量绘图器
///
/// 基于 205x206 像素的标准母版矢量坐标：
/// - 画布设计视口：(0, 0) ~ (205, 206)
/// - 天线圆球：cx=101.5, cy=15.5, r=16.5
/// - 天线立杆：left=95.0, top=30.0, right=108.0, bottom=59.0
/// - 外层头盔：Rect(0, 58, 203, 205), radius=38.0
/// - 内衬环框（挖空）：Rect(29, 86, 175, 177), radius=8.0
/// - 内部液晶屏：Rect(44, 101, 159, 162), radius=3.0
/// - 左眼：Rect(65, 119, 81, 144), radius=8.0
/// - 右眼：Rect(122, 119, 138, 144), radius=8.0
class _QRobotPainter extends CustomPainter {
  final Color bodyColor;
  final Color innerColor;
  final Color screenColor;

  const _QRobotPainter({
    required this.bodyColor,
    required this.innerColor,
    required this.screenColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 统一以 205x206 为基准坐标系缩放
    final scale = size.width / 205.0;
    canvas.save();
    canvas.scale(scale, scale * (size.height / size.width));

    final bodyPaint = Paint()
      ..color = bodyColor
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    final innerPaint = Paint()
      ..color = innerColor
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    final screenPaint = Paint()
      ..color = screenColor
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    // 1. 天线圆球
    canvas.drawCircle(const Offset(101.5, 15.5), 16.5, bodyPaint);

    // 2. 天线立杆
    canvas.drawRect(
      const Rect.fromLTRB(95.0, 30.0, 108.0, 60.0),
      bodyPaint,
    );

    // 3. 外层机身圆角矩形
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(0.0, 58.0, 203.0, 205.0),
        const Radius.circular(38.0),
      ),
      bodyPaint,
    );

    // 4. 内衬高亮环框（浅色或背景色）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(29.0, 86.0, 174.0, 177.0),
        const Radius.circular(8.0),
      ),
      innerPaint,
    );

    // 5. 内部液晶屏
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(44.0, 101.0, 159.0, 162.0),
        const Radius.circular(3.0),
      ),
      screenPaint,
    );

    // 6. 双眼（浅色圆角垂直胶囊）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(65.0, 119.0, 81.0, 144.0),
        const Radius.circular(8.0),
      ),
      innerPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(122.0, 119.0, 138.0, 144.0),
        const Radius.circular(8.0),
      ),
      innerPaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _QRobotPainter oldDelegate) {
    return oldDelegate.bodyColor != bodyColor ||
        oldDelegate.innerColor != innerColor ||
        oldDelegate.screenColor != screenColor;
  }
}
