import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_contrast.dart';

/// 主题色实心图标底座。
///
/// 用户自选主题色里包含荧光黄绿、春天亮绿这类极亮色，直接把强调色画在白底上
/// 只有 1.4:1 左右，图标会「糊」进背景。这里把底座铺成实心强调色，前景交给
/// [AppContrast.onColor] 自动取黑/白，任意主题色下都能保持 AA 以上的可读性
/// （荧光黄绿配黑图标约 14.9:1），视觉上与小Q头像、悬浮球的实心风格一致。
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.icon,
    this.size = 36,
    this.iconSize = 19,
    this.borderRadius,
    this.backgroundColor,
    this.foregroundColor,
    this.tooltip,
    this.onTap,
  });

  /// 图标。
  final IconData icon;

  /// 底座边长。
  final double size;

  /// 图标尺寸。
  final double iconSize;

  /// 圆角；为 null 时使用圆形底座。
  final BorderRadius? borderRadius;

  /// 底座颜色，默认取主题 primary。
  final Color? backgroundColor;

  /// 图标颜色，默认按底座亮度自动取黑/白。
  final Color? foregroundColor;

  /// 长按/悬停提示（可选）。
  final String? tooltip;

  /// 点击回调；为 null 时仅展示，不响应点击。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final background = backgroundColor ?? Theme.of(context).colorScheme.primary;
    final foreground = foregroundColor ?? AppContrast.onColor(background);
    final effectiveRadius = borderRadius ?? BorderRadius.circular(size / 2);

    Widget badge = Material(
      color: background,
      shape: RoundedRectangleBorder(borderRadius: effectiveRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: foreground.withValues(alpha: 0.18),
        highlightColor: foreground.withValues(alpha: 0.08),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      badge = Tooltip(message: tooltip, child: badge);
    }
    return badge;
  }
}
