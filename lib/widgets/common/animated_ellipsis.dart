import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 动态省略号：三个圆点依次渐显、周期尾整体淡出后循环，
/// 用于流式占位状态行，弱化"卡住不动"的等待感。
///
/// AI 主页面与小Q悬浮球的等待态共用组件，遵循小Q等待态显示规范
/// （严禁闪烁光标，统一用状态文案 + 动态省略号表达进行中）
class AnimatedEllipsis extends StatefulWidget {
  /// 圆点直径
  final double dotSize;

  /// 圆点间距（单侧 margin）
  final double dotSpacing;

  /// 圆点颜色，缺省取主题可读强调色 [AppThemeAccent.accentInk]
  final Color? color;

  const AnimatedEllipsis({super.key, this.dotSize = 4, this.dotSpacing = 1.5, this.color});

  @override
  State<AnimatedEllipsis> createState() => _AnimatedEllipsisState();
}

class _AnimatedEllipsisState extends State<AnimatedEllipsis> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  /// 系统「减弱动态效果」：停在三点全显的一帧，不再循环占用 ticker
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1350));
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = AppMotion.reduce(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _sync();
    }
  }

  void _sync() {
    if (_reduceMotion) {
      _controller
        ..stop()
        // 0.75 落在「三点全部显现且未开始整体淡出」的区间
        ..value = 0.75;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 第 [index] 个点在周期进度 [t]（0~1）下的透明度：错峰渐显 + 尾段整体淡出
  double _dotOpacity(double t, int index) {
    final start = 0.05 + index * 0.2;
    double opacity;
    if (t <= start) {
      opacity = 0.0;
    } else if (t < start + 0.2) {
      opacity = Curves.easeOut.transform((t - start) / 0.2);
    } else {
      opacity = 1.0;
    }
    // 周期最后 15% 整体淡出，循环衔接更自然
    if (t > 0.85) {
      opacity *= 1 - (t - 0.85) / 0.15;
    }
    return opacity.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).accentInk;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Container(
              width: widget.dotSize,
              height: widget.dotSize,
              margin: EdgeInsets.symmetric(horizontal: widget.dotSpacing),
              // 直接乘色值 alpha，避免每帧挂载 3 个独立的 Opacity 离屏合成层
              decoration: BoxDecoration(
                color: color.withValues(alpha: _dotOpacity(t, i)),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
