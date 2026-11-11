/// 全局字号令牌，统一组件中的字体大小。
///
/// 只定义「字号」这一维度，不包含字重、行高和颜色；调用方仍通过
/// `TextStyle` / `textTheme.copyWith` 组合这些属性，避免替换时改变既有视觉。
abstract class AppTypography {
  /// 微型辅助文字：热力图坐标刻度、体征徽标说明等最小可读字号。
  static const double micro = 9;

  /// 说明文字：图例、单位、图表刻度与次级补充说明。
  static const double caption = 10;

  /// 标签文字：状态徽标、行内标签与图表 tooltip 标题。
  static const double label = 11;

  /// 小号正文：紧凑按钮、筛选条、芯片与辅助信息。
  static const double bodySmall = 12;

  /// 正文：日记内容、应用名称、设置项与输入框文字。
  static const double body = 13;

  /// 大号正文：列表标题、Markdown 正文与维度名称。
  static const double bodyLarge = 14;

  /// 分区标题：卡片标题与主操作按钮文字。
  static const double subtitle = 15;

  /// 标题：空状态标题、统计数值与页面标题。
  static const double title = 16;

  /// 强调标题：评分等级、大号统计数字等需要突出的内容。
  static const double headline = 18;
}
