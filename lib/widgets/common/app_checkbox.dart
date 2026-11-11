import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 全应用统一的勾选指示器：圆角矩形外框 + 对勾。
///
/// Material 自带的 `Icons.check_box(_outline_blank)` 是直角方框，和项目里的
/// 圆角卡片、胶囊标签放在一起会显得没对齐；`Checkbox` 又自带水波纹和 48px
/// 命中区，塞进「整行可点」的列表里容易和父级手势抢事件。这里只负责视觉，
/// 点击交给外层整行或 [onTap] 处理。
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({
    super.key,
    required this.value,
    this.onTap,
    this.size = 20,
    this.activeColor,
    this.inactiveColor,
    this.checkColor,
  });

  /// 是否选中。
  final bool value;

  /// 独立点击回调；为 null 时仅作视觉指示器，由父级整行点击切换。
  final VoidCallback? onTap;

  /// 外框边长。圆角按边长等比取 30%，20px 时正好是 6px 圆角。
  final double size;

  /// 选中态填充色，默认取主题 primary。
  final Color? activeColor;

  /// 未选中态描边色，默认取主题 outline。
  final Color? inactiveColor;

  /// 对勾颜色，默认取主题 onPrimary。
  final Color? checkColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final active = activeColor ?? colorScheme.primary;
    final inactive = inactiveColor ?? colorScheme.outline;

    final Widget indicator = AnimatedContainer(
      duration: AppMotion.duration(context, AppDurations.fast),
      curve: AppCurves.standard,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: value ? active : Colors.transparent,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: value ? active : inactive, width: 1.8),
      ),
      child: AnimatedScale(
        scale: value ? 1 : 0,
        duration: AppMotion.duration(context, AppDurations.fast),
        curve: AppCurves.spring,
        child: Icon(Icons.check_rounded, size: size * 0.68, color: checkColor ?? colorScheme.onPrimary),
      ),
    );

    if (onTap == null) {
      return Semantics(checked: value, child: indicator);
    }
    return Semantics(
      checked: value,
      onTap: onTap,
      child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: indicator),
    );
  }
}
