import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  const SettingsSegmentBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onChanged,
  });

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
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.fastOutSlowIn,
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
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
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
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
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
