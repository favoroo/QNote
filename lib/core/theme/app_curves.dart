import 'package:flutter/material.dart';

/// 全局动效曲线令牌，与 [AppDurations] 配合使用。
///
/// 遵循 Material 3 动效规范，保持应用内节奏一致：
/// - [standard]: 标准双向平滑，适用于多数尺寸/透明度/颜色过渡
/// - [emphasized]: 强调入场，减速更柔和，适用于新元素进入视口
/// - [exit]: 快速退场，加速离开视口，不拖泥带水
/// - [spring]: 轻微弹性，适用于打勾、轻按、徽章等触觉反馈强烈的点缀场景
abstract class AppCurves {
  /// 标准平滑曲线 (easeInOut)
  static const Curve standard = Curves.easeInOut;

  /// 强调型入场曲线 (easeOutCubic)
  static const Curve emphasized = Curves.easeOutCubic;

  /// 快速离开曲线 (easeIn)
  static const Curve exit = Curves.easeIn;

  /// 轻弹性曲线 (easeOutBack)
  static const Curve spring = Curves.easeOutBack;
}
