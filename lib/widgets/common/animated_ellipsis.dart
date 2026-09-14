import 'package:flutter/material.dart';

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

  /// 圆点颜色，缺省取主题 primary
  final Color? color;

  const AnimatedEllipsis({
    super.key,
    this.dotSize = 4,
    this.dotSpacing = 1.5,
    this.color,
  });

  @override
  State<AnimatedEllipsis> createState() => _AnimatedEllipsisState();
}

class _AnimatedEllipsisState extends State<AnimatedEllipsis>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    )..repeat();
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
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Opacity(
              opacity: _dotOpacity(t, i),
              child: Container(
                width: widget.dotSize,
                height: widget.dotSize,
                margin: EdgeInsets.symmetric(horizontal: widget.dotSpacing),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            );
          }),
        );
      },
    );
  }
}
