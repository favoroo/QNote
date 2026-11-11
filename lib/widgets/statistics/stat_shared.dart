import 'package:flutter/material.dart';

import 'package:fl_chart/fl_chart.dart';

import 'package:qnote_flutter/core/theme/app_palette.dart';

/// 统计卡片外框：统一 16 圆角、0.5 细边框、零阴影与 16 内边距。
///
/// 所有统计卡片共用该外框，避免各组件重复维护卡片装饰导致视觉漂移。
class StatCardContainer extends StatelessWidget {
  /// 是否为深色主题。
  final bool isDark;

  /// 卡片内容。
  final Widget child;

  const StatCardContainer({super.key, required this.isDark, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppPalette.border(isDark), width: 0.5),
      ),
      elevation: 0,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

/// 统计卡片标题前的方形图标徽标。
class StatIconChip extends StatelessWidget {
  /// 图标。
  final IconData icon;

  /// 图标颜色。
  final Color color;

  /// 徽标底色。
  final Color backgroundColor;

  const StatIconChip({super.key, required this.icon, required this.color, required this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: backgroundColor, borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// 带标题栏的统计卡片。
///
/// [leading] 用于标题前图标，[trailing] 用于标题右侧附加内容；二者同时提供时
/// 仅展示 [leading]，以保持标题栏结构稳定。
class StatCardShell extends StatelessWidget {
  /// 是否为深色主题。
  final bool isDark;

  /// 卡片标题。
  final String title;

  /// 标题栏下方的卡片内容。
  final Widget child;

  /// 标题前图标。
  final Widget? leading;

  /// 标题右侧附加内容。
  final Widget? trailing;

  const StatCardShell({
    super.key,
    required this.isDark,
    required this.title,
    required this.child,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final titleText = Text(
      title,
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppPalette.textPrimary(isDark)),
    );

    final Widget header;
    if (leading != null) {
      header = Row(children: [leading!, const SizedBox(width: 8), titleText]);
    } else if (trailing != null) {
      header = Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [titleText, trailing!]);
    } else {
      header = titleText;
    }

    return StatCardContainer(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, const SizedBox(height: 16), child],
      ),
    );
  }
}

/// 两张并排等宽的统计数值卡。
class StatsCardPair extends StatelessWidget {
  /// 左侧卡片。
  final Widget left;

  /// 右侧卡片。
  final Widget right;

  /// 两卡之间的水平间距。
  final double gap;

  const StatsCardPair({super.key, required this.left, required this.right, this.gap = 12});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: left),
        if (gap > 0) SizedBox(width: gap),
        Expanded(child: right),
      ],
    );
  }
}

/// 固定高度的统计图表区域，无数据时展示统一空态文案。
class StatChartBox extends StatelessWidget {
  /// 图表区域高度。
  final double height;

  /// 数据是否为空；为空时展示「暂无数据」。
  final bool isEmpty;

  /// 数据非空时展示的图表。
  final Widget child;

  const StatChartBox({super.key, required this.height, required this.isEmpty, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: isEmpty
          ? const Center(
              child: Text('暂无数据', style: TextStyle(color: AppPalette.textMuted)),
            )
          : child,
    );
  }
}

/// 带图例的占比饼图。
///
/// [colorOf] 由业务方按分类名称与序号提供颜色，组件只负责统一的饼图与图例布局。
class StatPieChart extends StatelessWidget {
  /// 是否为深色主题。
  final bool isDark;

  /// 分类名称与数值。
  final List<MapEntry<String, int>> data;

  /// 分类颜色解析器，参数依次为分类名称、分类序号。
  final Color Function(String label, int index) colorOf;

  const StatPieChart({super.key, required this.isDark, required this.data, required this.colorOf});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 200,
          child: PieChart(
            PieChartData(
              sections: data.asMap().entries.map((e) {
                final color = colorOf(e.value.key, e.key);
                return PieChartSectionData(
                  value: e.value.value.toDouble(),
                  color: color,
                  radius: 60,
                  title: '${e.value.value}',
                  titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                );
              }).toList(),
              sectionsSpace: 2,
              centerSpaceRadius: 28,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: data.asMap().entries.map((e) {
            final color = colorOf(e.value.key, e.key);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  '${e.value.key} (${e.value.value})',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppPalette.textSecondary(isDark)),
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// 统一样式的圆角进度条。
class StatProgressBar extends StatelessWidget {
  /// 是否为深色主题。
  final bool isDark;

  /// 进度值，范围为 0~1。
  final double value;

  /// 进度前景色。
  final Color color;

  /// 进度条高度。
  final double minHeight;

  const StatProgressBar({
    super.key,
    required this.isDark,
    required this.value,
    required this.color,
    required this.minHeight,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: value,
        backgroundColor: AppPalette.progressTrack(isDark),
        valueColor: AlwaysStoppedAnimation(color),
        minHeight: minHeight,
      ),
    );
  }
}
