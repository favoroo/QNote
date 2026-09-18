import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 小Q 机器人绘制风格。
enum QRobotStyle {
  /// 实心填充：机身外壳 + 内衬环框 + 液晶屏 + 双眼，层次饱满。
  /// 适合头像、大尺寸展示与强调态。
  solid,

  /// 线稿描边：仅机身轮廓、天线与双眼，无内部填充。
  /// 线条轻盈，视觉重量与 Material 24px 图标（约 2px 描边）对齐，
  /// 适合小尺寸图标与未选中态。
  outlined,
}

/// 小Q 专属单体图标（轻量无圆形底座）。
///
/// 适用于导航栏、操作菜单（ActionMenu）、对话框头部的 Icon 场景。
/// 默认采用细线稿轮廓，线条视觉重量与同尺寸的 Material 图标保持一致；
/// 需要更强辨识度时（如导航栏选中态）传 [filled] 切换为实心填充风格。
class QIcon extends StatelessWidget {
  /// 小尺寸图标的内容收缩比例。
  ///
  /// 母版图形上下顶满画布（天线球几乎贴到顶边），直接渲染会比 Material 图标
  /// 更显臃肿；整体收缩后四周留出约 1.9px @24px 的呼吸边距。
  static const double _contentScale = 0.85;

  final double size;
  final Color? color;
  final Color? screenColor;
  final Color? eyeColor;

  /// 是否使用实心填充风格（[QRobotStyle.solid]）。
  ///
  /// - `false`（默认）：细线稿轮廓，线条厚度约 2px @24px，与导航栏其余
  ///   Material 图标（`Icons.book_outlined` 等）视觉重量一致
  /// - `true`：实心机器人，适合导航栏选中态等需要强辨识度的场景
  final bool filled;

  /// 眼睛张合程度（0.0 ~ 1.0），默认为 1.0（完全睁开）。
  ///
  /// 用于选中时的呼吸/眨眼动效：
  /// - 1.0：完全睁开（竖直胶囊眼）
  /// - 0.0：闭合（压缩为扁平圆角细缝，保留生动俏皮的弧度和表情）
  final double eyeOpenness;

  const QIcon({
    super.key,
    this.size = 20,
    this.color,
    this.screenColor,
    this.eyeColor,
    this.filled = false,
    this.eyeOpenness = 1.0,
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
          style: filled ? QRobotStyle.solid : QRobotStyle.outlined,
          contentScale: _contentScale,
          eyeOpenness: eyeOpenness,
        ),
      ),
    );
  }
}

/// 小Q 专属机器人头像 / 图标组件。
///
/// 严格依据小Q专属机器人视觉几何规范（天线圆球+天线杆、圆角头盔、内衬环形外框、数码屏幕与双胶囊眼睛）绘制。
/// 可自适应任意尺寸（小至 14px 图标，大至 80px+ 头像），支持自定义主色（机器人机身）与副色（内衬/眼睛）。
/// 线条粗细与 [QIcon] 选中态共用同一内缩比例，保证全局小Q形象一致。
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

  /// 眼睛张合程度（0.0 ~ 1.0），默认为 1.0（完全睁开）。
  final double eyeOpenness;

  const QAvatar({
    super.key,
    this.size = 24,
    this.color,
    this.screenColor,
    this.eyeColor,
    this.withBackground = false,
    this.backgroundColor,
    this.padding = const EdgeInsets.all(4),
    this.eyeOpenness = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    // 当 withBackground = true 时，默认采用用户最青睐的「白净通透机身」视觉：
    // 底座为实心 primary 主色，机身为纯白 onPrimary，屏幕为 primary，内圈与眼睛为 onPrimary 纯白；
    // 这样头像在列表与气泡中具备极高辨识度与现代质感。
    final effectiveColor = color ??
        (withBackground
            ? theme.colorScheme.onPrimary
            : primary);

    final effectiveScreenColor = screenColor ??
        (withBackground
            ? (backgroundColor ?? primary)
            : primary);

    final effectiveEyeColor = eyeColor ??
        (withBackground
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.surface);

    final iconWidget = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        size: Size(size, size),
        painter: _QRobotPainter(
          bodyColor: effectiveColor,
          innerColor: effectiveEyeColor,
          screenColor: effectiveScreenColor,
          eyeOpenness: eyeOpenness,
        ),
      ),
    );

    if (!withBackground) {
      return iconWidget;
    }

    final effectiveBg = backgroundColor ?? primary;

    // 严谨对齐原图比例：在蓝色实心圆底座中，居中渲染高亮纯白机器人
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: effectiveBg,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: effectiveBg.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Center(
        child: SizedBox(
          width: size * 0.54,
          height: size * 0.54,
          child: CustomPaint(
            size: Size(size * 0.54, size * 0.54),
            painter: _QRobotPainter(
              bodyColor: effectiveColor,
              innerColor: effectiveEyeColor,
              screenColor: effectiveScreenColor,
              eyeOpenness: eyeOpenness,
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
/// - 内衬环框 / 液晶屏：按内缩量排布（母版 44.0，默认已收窄至 34.0，二者按比例跟随）
/// - 双眼：由液晶屏宽度按母版比例派生（母版屏幕宽 115 内排布 16x25、双眼中距 57），
///   垂直居中于机身；屏幕放大时宽高同倍率放大，造型不变形且小尺寸下仍可辨
///
/// 注：`QAvatar` 带背景时机器人仅占容器的 54%（24px 容器 → 机器人 12.96px），
/// 眼睛若沿用固定母版尺寸会细到约 1.0x1.6px，故改为随屏幕联动。
///
/// [QRobotStyle.outlined] 线稿模式改用「描边线宽」建模：
/// - 描边宽度 20.0（经 [contentScale] 收缩后约 2.0px @24px，对齐 Material 图标）
/// - 机身轮廓路径按线宽内缩一半，保证外缘仍与母版对齐
/// - 天线球与双眼为实心填充，尺寸与线宽协调（球直径≈1.55 倍线宽）
class _QRobotPainter extends CustomPainter {
  /// 线稿模式的描边宽度（母版坐标系）
  static const double _outlinedStroke = 20.0;

  /// 线稿模式天线球半径
  static const double _outlinedBallRadius = 15.5;

  /// 线稿模式天线球圆心
  static const Offset _outlinedBallCenter = Offset(101.5, 16.0);

  /// 线稿模式双眼胶囊宽度（与线宽一致）
  static const double _outlinedEyeWidth = 20.0;

  /// 线稿模式双眼胶囊高度
  static const double _outlinedEyeHeight = 30.0;

  /// 线稿模式双眼中心间距
  static const double _outlinedEyeGap = 62.0;

  /// 母版图形几何中心（用于 [contentScale] 收缩的基准点）
  static const Offset _masterCenter = Offset(101.5, 102.75);

  /// 实心模式机身边框内缩量（母版坐标系），决定机器人「线条」的视觉粗细。
  ///
  /// 母版原稿为 44.0；收窄至 34.0 后线条视觉重量贴近 Material 图标，
  /// 导航栏选中态与各处 [QAvatar] 头像共用同一比例，保持全局形象一致。
  static const double _solidFrameInset = 34.0;

  /// 双眼几何相对「液晶屏」的比例基准。
  ///
  /// 母版 44.0 内缩时屏幕宽 115，其中排布 16x25 的双眼、双眼中距 57；三个比例由此换算。
  /// 屏幕随 [_solidFrameInset] 收窄而放大时，双眼按屏幕宽度的缩放系数**等比**放大
  /// （宽高同倍率，故胶囊造型恒定不变形）——否则 24px 头像下双眼仅约 1.0x1.6px，细到不可辨。
  static const double _masterScreenWidth = 203.0 - 44.0 * 2;
  static const double _eyeWidthRatio = 16.0 / _masterScreenWidth;
  static const double _eyeGapRatio = 57.0 / _masterScreenWidth;

  /// 双眼高宽比（母版造型：竖长胶囊 25/16）。
  ///
  /// 高度由宽度乘此比例派生，而非各轴独立缩放，避免屏幕纵向放大更多时眼睛被拉长变形。
  static const double _eyeAspect = 25.0 / 16.0;

  /// 双眼垂直中心：机身 y 轴 58~205 的中心，恰好也是液晶屏的垂直中心。
  static const double _eyeCenterY = 131.5;

  final Color bodyColor;
  final Color innerColor;
  final Color screenColor;
  final QRobotStyle style;

  /// 内容整体收缩比例（以 [_masterCenter] 为基准），1.0 表示铺满母版画布。
  final double contentScale;

  /// 眼睛睁开程度（0.0 ~ 1.0），1.0 为完全睁开（竖胶囊），0.0 为眨眼闭合（圆角扁缝）
  final double eyeOpenness;

  const _QRobotPainter({
    required this.bodyColor,
    required this.innerColor,
    required this.screenColor,
    this.style = QRobotStyle.solid,
    this.contentScale = 1.0,
    this.eyeOpenness = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 统一以 205x206 为基准坐标系缩放
    final scale = size.width / 205.0;
    canvas.save();
    canvas.scale(scale, scale * (size.height / size.width));

    if (contentScale != 1.0) {
      // 以图形几何中心为基准整体收缩，四周留出与 Material 图标一致的呼吸边距
      canvas.translate(_masterCenter.dx, _masterCenter.dy);
      canvas.scale(contentScale, contentScale);
      canvas.translate(-_masterCenter.dx, -_masterCenter.dy);
    }

    if (style == QRobotStyle.outlined) {
      _paintOutlined(canvas);
    } else {
      _paintSolid(canvas);
    }

    canvas.restore();
  }

  /// 实心填充：机身外壳 → 内衬环框 → 液晶屏 → 双眼，逐层挖空形成层次
  void _paintSolid(Canvas canvas) {
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

    // 内衬环框保持母版比例（29 / 44 ≈ 0.66）
    const innerInset = _solidFrameInset * 0.66;
    // 同心圆角：内层圆角随边框收窄而增大，避免出现生硬直角
    final screenRadius = math.max(3.0, 38.0 - _solidFrameInset);
    // 液晶屏宽度（机身宽 203 四边内缩 _solidFrameInset），双眼比例以此为基准
    const screenWidth = 203.0 - _solidFrameInset * 2;

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
        const Rect.fromLTRB(
          innerInset,
          58.0 + innerInset,
          203.0 - innerInset,
          205.0 - innerInset,
        ),
        const Radius.circular(8.0),
      ),
      innerPaint,
    );

    // 5. 内部液晶屏
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(
          _solidFrameInset,
          58.0 + _solidFrameInset,
          203.0 - _solidFrameInset,
          205.0 - _solidFrameInset,
        ),
        Radius.circular(screenRadius),
      ),
      screenPaint,
    );

    // 6. 双眼（浅色圆角垂直胶囊）
    //    尺寸由屏幕宽度按母版比例派生，屏幕放大时眼睛同步等比放大且造型不变形；
    //    垂直居中于机身，圆角取半宽使其保持胶囊形。
    //    支持 eyeOpenness 动态眨眼：完全闭合时保留圆润扁缝（minHeight = eyeWidth * 0.18）
    const eyeWidth = screenWidth * _eyeWidthRatio;
    const eyeHeight = eyeWidth * _eyeAspect;
    const eyeGap = screenWidth * _eyeGapRatio;
    final clampedOpenness = eyeOpenness.clamp(0.0, 1.0);
    const minEyeHeight = eyeWidth * 0.18;
    final currentEyeHeight = math.max(minEyeHeight, eyeHeight * clampedOpenness);
    final currentRadius = Radius.circular(currentEyeHeight / 2);

    for (final dx in <double>[-eyeGap / 2, eyeGap / 2]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(101.5 + dx, _eyeCenterY),
            width: eyeWidth,
            height: currentEyeHeight,
          ),
          currentRadius,
        ),
        innerPaint,
      );
    }
  }

  /// 线稿轮廓：仅描边机身边框并填充天线与双眼，线条轻盈
  void _paintOutlined(Canvas canvas) {
    final fillPaint = Paint()
      ..color = bodyColor
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = bodyColor
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = _outlinedStroke
      ..strokeJoin = StrokeJoin.round;

    const half = _outlinedStroke / 2;

    // 1. 天线圆球（实心圆点）
    canvas.drawCircle(_outlinedBallCenter, _outlinedBallRadius, fillPaint);

    // 2. 天线立杆：宽度与描边一致，自球心垂直落入机身顶边
    canvas.drawRect(
      Rect.fromLTRB(
        101.5 - half,
        _outlinedBallCenter.dy,
        101.5 + half,
        58.0 + half,
      ),
      fillPaint,
    );

    // 3. 机身轮廓：路径按线宽内缩一半，使描边外缘与母版机身边缘对齐
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(0.0, 58.0, 203.0, 205.0).inflate(-half),
        const Radius.circular(38.0 - half),
      ),
      strokePaint,
    );

    // 4. 双眼：竖向胶囊，垂直居中于机身（支持 eyeOpenness 动态眨眼）
    const eyeCenter = Offset(101.5, 131.5);
    final clampedOpenness = eyeOpenness.clamp(0.0, 1.0);
    const minOutlinedEyeHeight = _outlinedEyeWidth * 0.18;
    final currentOutlinedEyeHeight = math.max(
      minOutlinedEyeHeight,
      _outlinedEyeHeight * clampedOpenness,
    );
    final currentOutlinedRadius = Radius.circular(currentOutlinedEyeHeight / 2);

    for (final dx in <double>[-_outlinedEyeGap / 2, _outlinedEyeGap / 2]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(eyeCenter.dx + dx, eyeCenter.dy),
            width: _outlinedEyeWidth,
            height: currentOutlinedEyeHeight,
          ),
          currentOutlinedRadius,
        ),
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QRobotPainter oldDelegate) {
    return oldDelegate.bodyColor != bodyColor ||
        oldDelegate.innerColor != innerColor ||
        oldDelegate.screenColor != screenColor ||
        oldDelegate.style != style ||
        oldDelegate.contentScale != contentScale ||
        oldDelegate.eyeOpenness != eyeOpenness;
  }
}
