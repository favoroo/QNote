import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

/// 设置页分区切换器的单个分区描述
class SettingsSegmentItem {
  final String title;
  final IconData icon;

  const SettingsSegmentItem({required this.title, required this.icon});
}

/// 设置页顶部的分段式分区切换器。
///
/// 小Q设置、快捷记录、健康数据三个综合设置页共用同一套视觉与动效：
/// 单个平移的白色胶囊作为选中态，图标与文字随选中态渐变着色。
/// 之所以抽成组件而不是各页各写一份：这类页面靠「同一屏内的横向切换」表达
/// 同一板块下的子功能，胶囊样式一旦各写一份就会在圆角、阴影、动效时长上慢慢分叉。
///
/// [items] 按等分宽度排布，建议不超过 4 个（再多文字会挤成省略号）。
class SettingsSegmentBar extends StatelessWidget {
  const SettingsSegmentBar({super.key, required this.items, required this.selectedIndex, required this.onChanged});

  final List<SettingsSegmentItem> items;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  static const double _padding = 4;
  static const double _height = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      padding: const EdgeInsets.all(_padding),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / items.length;

          return SizedBox(
            height: _height,
            child: Stack(
              children: [
                // 唯一的平移胶囊：任何时刻都只有一个选中滑块，不会出现双高亮
                AnimatedPositioned(
                  duration: AppMotion.duration(context, AppDurations.page),
                  curve: AppCurves.emphasizedSpatial,
                  left: selectedIndex * tabWidth,
                  top: 0,
                  width: tabWidth,
                  height: _height,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: List.generate(items.length, (index) {
                    final selected = index == selectedIndex;
                    final item = items[index];
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (selected) return;
                          HapticFeedback.selectionClick();
                          onChanged(index);
                        },
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.duration(context, AppDurations.normal),
                            curve: AppCurves.standard,
                            style: theme.textTheme.bodyMedium!.copyWith(
                              fontSize: 13,
                              fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                              color: selected
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TweenAnimationBuilder<Color?>(
                                  duration: AppMotion.duration(context, AppDurations.normal),
                                  curve: AppCurves.standard,
                                  tween: ColorTween(
                                    begin: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                    end: selected
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                  ),
                                  builder: (context, iconColor, child) {
                                    return Icon(item.icon, size: 16, color: iconColor);
                                  },
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    item.title,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 分段页内容切换过渡。
///
/// 内部通常放 [IndexedStack] 以保留各分段的滚动位置与编辑态；`index` 变化时
/// 只对新内容做一次短促的淡入 + 4px 上移，避免「胶囊滑过去了、内容啪一下换掉」。
/// 只做位移与透明度，不改变子树结构，因此不会打断 [IndexedStack] 的状态。
class SettingsSegmentContent extends StatefulWidget {
  final int index;
  final Widget child;

  const SettingsSegmentContent({super.key, required this.index, required this.child});

  @override
  State<SettingsSegmentContent> createState() => _SettingsSegmentContentState();
}

class _SettingsSegmentContentState extends State<SettingsSegmentContent> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDurations.normal, value: 1.0);
    final curved = CurvedAnimation(parent: _controller, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
    _opacity = Tween<double>(begin: 0.55, end: 1.0).animate(curved);
    _offset = Tween<Offset>(begin: const Offset(0, 0.008), end: Offset.zero).animate(curved);
  }

  @override
  void didUpdateWidget(covariant SettingsSegmentContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    if (AppMotion.reduce(context)) {
      _controller.value = 1.0;
    } else {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(position: _offset, child: widget.child),
      ),
    );
  }
}
