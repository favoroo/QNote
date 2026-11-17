import 'package:flutter/material.dart';

/// 时间线标签的语义色。
///
/// 每个标签给出浅色 / 深色两支色值：浅色主题取 Tailwind 600 档（比 700 档更鲜亮，
/// 避免琥珀、青绿这类色相压深后发闷发褐），深色主题取 400 档保证深底可读。
///
/// 色值本身只保证**图形级**对比度（WCAG 1.4.11 的 3:1）——它直接用作图标、进度圈、
/// 轴线圆点、卡片描边。会作为文字出现的地方（胶囊标签、字段名）一律走
/// `AppContrast.inkOnTint` 在同色淡底上压深到 4.5:1，不依赖原色本身达标。
///
/// 「活动」「健康」「运动健康」过去共用同一支翡翠绿，多标签卡片并排时无法区分，
/// 现在拆成绿 / 蓝 / 青三支；其余标签保持原有色相，只提高明度。
abstract class TagColors {
  /// 睡眠：紫，贴合「夜晚」直觉。
  static const Color sleepLight = Color(0xFF7C3AED);
  static const Color sleepDark = Color(0xFFA78BFA);

  /// 饮食：橙，比琥珀更暖更亮，避免压深后发褐。
  static const Color dietLight = Color(0xFFEA580C);
  static const Color dietDark = Color(0xFFFB923C);

  /// 活动：翡翠绿。
  static const Color activityLight = Color(0xFF059669);
  static const Color activityDark = Color(0xFF34D399);

  /// 健康（身体症状 / 用药）：蓝，与「活动」绿拆开。
  static const Color healthLight = Color(0xFF2563EB);
  static const Color healthDark = Color(0xFF60A5FA);

  /// 运动健康（小米运动健康日结）：青，与「活动」「健康」都不撞色。
  static const Color fitnessLight = Color(0xFF0891B2);
  static const Color fitnessDark = Color(0xFF22D3EE);

  /// 记账：红。
  static const Color financeLight = Color(0xFFDC2626);
  static const Color financeDark = Color(0xFFF87171);

  /// 随想：玫粉。
  static const Color thoughtLight = Color(0xFFDB2777);
  static const Color thoughtDark = Color(0xFFF472B6);

  /// 兜底色：自定义标签、「其他」、「记录」这类未归类记录。
  static const Color defaultTagLight = Color(0xFF6B7280);
  static const Color defaultTagDark = Color(0xFF9CA3AF);

  /// 内置标签名，供测试与需要遍历全部标签色的场景使用。
  static const List<String> knownTags = ['睡眠', '饮食', '活动', '健康', '运动健康', '记账', '随想'];

  static Color sleep(Brightness brightness) => _pick(brightness, sleepLight, sleepDark);

  static Color diet(Brightness brightness) => _pick(brightness, dietLight, dietDark);

  static Color activity(Brightness brightness) => _pick(brightness, activityLight, activityDark);

  static Color health(Brightness brightness) => _pick(brightness, healthLight, healthDark);

  static Color fitness(Brightness brightness) => _pick(brightness, fitnessLight, fitnessDark);

  static Color finance(Brightness brightness) => _pick(brightness, financeLight, financeDark);

  static Color thought(Brightness brightness) => _pick(brightness, thoughtLight, thoughtDark);

  static Color defaultTag(Brightness brightness) => _pick(brightness, defaultTagLight, defaultTagDark);

  /// 按显示标签取色；未知标签（自定义标签、「其他」）落到中性灰。
  static Color of(String displayTag, Brightness brightness) {
    switch (displayTag) {
      case '睡眠':
        return sleep(brightness);
      case '饮食':
        return diet(brightness);
      case '活动':
        return activity(brightness);
      case '健康':
        return health(brightness);
      case '运动健康':
        return fitness(brightness);
      case '记账':
        return finance(brightness);
      case '随想':
        return thought(brightness);
      default:
        return defaultTag(brightness);
    }
  }

  static Color _pick(Brightness brightness, Color light, Color dark) => brightness == Brightness.dark ? dark : light;
}
