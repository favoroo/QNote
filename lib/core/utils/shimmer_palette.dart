import 'package:flutter/material.dart';

/// 一组沿描边旋转的「柔光」配色。
///
/// [colors] 与 [stops] 等长，且首尾颜色一致，保证 0° / 360° 接缝处不出现硬切。
@immutable
class ShimmerPalette {
  const ShimmerPalette({required this.colors, required this.stops});

  final List<Color> colors;
  final List<double> stops;
}

/// 双彗尾柔光的默认渐变断点。
///
/// 每道彗尾由「透明尾部 → 主题色低透明段 → 中段 → 微提亮高光 → 中段 → 低透明段」
/// 组成。高光只占一个断点，靠两侧插值形成宽而软的头部，避免出现一个刺眼的亮点；
/// 两道彗尾相隔 0.5，绕卡片时保持对称。
const List<double> shimmerPaletteStops = [
  0.00,
  0.03,
  0.09,
  0.16,
  0.21,
  0.26,
  0.33,
  0.40,
  0.50,
  0.53,
  0.59,
  0.66,
  0.71,
  0.76,
  0.83,
  0.90,
  1.00,
];

/// 构建深浅色通用的柔光配色。
///
/// 设计取舍：
/// - 深色下不再把主题色混到接近纯白（旧版按 0.88 向白插值），纯白描边放在深色
///   卡片上对比过强，像一圈发光的白塑料；这里最高只提亮 24%，高光仍保留主题色
///   相，观感是「主题色的光」而不是「白光」。
/// - 亮色下提亮幅度更小（10%），否则亮度较高的主题色会被提成浅色，在白卡片上
///   发虚、失去轮廓。
/// - 轨道保留一层低透明度主题色：提取中的卡片自身边框是透明的，没有这层轨道时，
///   彗尾转到背面会让卡片短暂「没有边」。
ShimmerPalette buildShimmerPalette({required Color primary, required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final track = primary.withValues(alpha: isDark ? 0.12 : 0.08);
  final low = primary.withValues(alpha: isDark ? 0.20 : 0.16);
  final mid = primary.withValues(alpha: isDark ? 0.50 : 0.42);
  final head = Color.lerp(primary, Colors.white, isDark ? 0.24 : 0.10)!.withValues(alpha: isDark ? 0.92 : 0.88);

  return ShimmerPalette(
    colors: [track, track, low, mid, head, mid, low, track, track, track, low, mid, head, mid, low, track, track],
    stops: shimmerPaletteStops,
  );
}
