import 'dart:math' as math;

/// QStyle 网页风格家族
///
/// - [magazine]：杂志风，衬线标题 + 暖纸底 + 大留白，适合叙事与人文内容；
/// - [swiss]：瑞士风，无衬线 + 单一高饱和锚点色 + 直角纯色，适合数据与工具页面。
enum QStyleFamily {
  magazine('magazine', '杂志风'),
  swiss('swiss', '瑞士风');

  const QStyleFamily(this.id, this.label);

  /// 写入 `<html data-family="...">` 的值
  final String id;

  /// 中文展示名
  final String label;
}

/// 家族公共设计 token（与具体主题色无关）
extension QStyleFamilyTokens on QStyleFamily {
  /// 标题字体栈：杂志风用衬线做视觉重音，瑞士风全程无衬线
  String get fontDisplay {
    if (this == QStyleFamily.magazine) {
      return "'Noto Serif SC','Songti SC','STSong','Source Han Serif SC',serif";
    }
    return "'Noto Sans SC','PingFang SC','Helvetica Neue','Microsoft YaHei',sans-serif";
  }

  /// 正文字体栈
  String get fontBody => "'Noto Sans SC','PingFang SC','Microsoft YaHei',sans-serif";

  /// 等宽标签字体栈（kicker / meta / 图注）
  String get fontMono => "'IBM Plex Mono','SF Mono','Menlo',ui-monospace,monospace";

  /// 圆角：杂志风允许 2px 微圆角，瑞士风必须全直角
  String get radius => this == QStyleFamily.magazine ? '2px' : '0px';

  /// 家族公共 token 的 CSS 块（不含颜色，颜色见各主题的 [QStyleTheme.cssBlock]）
  String get cssTokensBlock =>
      ':root{'
      '--gutter:20px;--maxw:640px;'
      '--sp-1:4px;--sp-2:8px;--sp-3:12px;--sp-4:16px;--sp-5:24px;--sp-6:32px;--sp-7:48px;--sp-8:64px;--sp-9:96px;'
      '--font-display:$fontDisplay;--font-body:$fontBody;--font-mono:$fontMono;'
      '--fs-display:clamp(40px,12.5vw,56px);--fs-h1:clamp(28px,8.4vw,36px);--fs-h2:clamp(22px,6.4vw,28px);'
      '--fs-h3:19px;--fs-lead:18px;--fs-body:16px;--fs-small:14px;--fs-micro:12px;'
      '--r:$radius;--ease:cubic-bezier(.2,.7,.2,1);--dur:.3s;'
      '}';
}

/// 一套 QStyle 网页主题
///
/// **新增风格只加一条数据**：提供 [id]、[name]、[family]、[paper]、[ink]、[accent]、
/// [suitableFor] 七个字段即可，派生色、对比度、CSS token 块与主题决策表全部自动生成。
///
/// 新增后必须运行 `flutter test test/core/agent/skills/frontend_design_doc_test.dart`：
/// 对比度不达标或 id 重复会直接报错，CI 同样会拦截，避免「看起来能用但读不清」的配色混进来。
class QStyleTheme {
  const QStyleTheme({
    required this.id,
    required this.name,
    required this.family,
    required this.paper,
    required this.ink,
    required this.accent,
    required this.suitableFor,
  });

  /// 主题 id，写入 `<html data-theme="...">`
  final String id;

  /// 中文主题名
  final String name;

  /// 所属风格家族
  final QStyleFamily family;

  /// 纸底（页面背景）
  final String paper;

  /// 墨色（主文字）
  final String ink;

  /// 强调色（色块 / 下划线 / 数字）
  final String accent;

  /// 适合的内容类型，用于生成主题决策表
  final String suitableFor;

  /// 暗色主题：纸底亮度低于 0.3
  bool get isDark => luminance(paper) < 0.3;

  /// 区块 / 卡片底（纸底向墨色混 5%）
  String get paper2 => mixHex(paper, ink, 0.05);

  /// 次要文字（向墨色混 82%，对比度 ≥ 7:1）
  String get text2 => mixHex(paper, ink, 0.82);

  /// 辅助文字（向墨色混 68%，对比度 ≥ 4.5:1）
  String get text3 => mixHex(paper, ink, 0.68);

  /// 发丝分割线（向墨色混 16%）
  String get line => mixHex(paper, ink, 0.16);

  /// 强分割线 / 描边（向墨色混 30%）
  String get lineStrong => mixHex(paper, ink, 0.30);

  /// 荧光标记底（仅杂志风使用；瑞士风禁止色块加色）
  String get accentSoft => mixHex(paper, accent, 0.10);

  /// 强调色用作小字时的颜色：不足 4.5:1 时自动加深（亮底）或提亮（暗底）
  String get accentInk {
    if (contrastRatio(accent, paper) >= 4.5) {
      return accent;
    }
    return isDark ? _lightenUntil(accent, paper, 4.5) : _darkenUntil(accent, paper, 4.5);
  }

  /// 强调色块上的文字颜色：取白 / 近黑里对比度更高者
  String get accentOn => contrastRatio('#ffffff', accent) >= contrastRatio('#0a0a0a', accent) ? '#ffffff' : '#0a0a0a';

  /// 主文字对比度
  double get contrastInk => contrastRatio(ink, paper);

  /// 次要文字对比度
  double get contrastText2 => contrastRatio(text2, paper);

  /// 辅助文字对比度
  double get contrastText3 => contrastRatio(text3, paper);

  /// 强调小字对比度
  double get contrastAccentInk => contrastRatio(accentInk, paper);

  /// 色块文字对比度
  double get contrastAccentOn => contrastRatio(accentOn, accent);

  /// 生成提示词里的 CSS 变量块（单行，模型整体复制即可，避免自己算色）
  String get cssBlock {
    final variables = <String>[
      '--paper:$paper',
      '--paper-2:$paper2',
      '--ink:$ink',
      '--text-2:$text2',
      '--text-3:$text3',
      '--line:$line',
      '--line-strong:$lineStrong',
      '--accent:$accent',
      '--accent-ink:$accentInk',
      '--accent-on:$accentOn',
      if (family == QStyleFamily.magazine) '--accent-soft:$accentSoft',
      if (isDark) 'color-scheme:dark',
    ];
    return '[data-theme="$id"]{${variables.join(';')}}';
  }
}

/// 全部 QStyle 主题（顺序即主题决策表顺序）
///
/// 新增主题时按家族分组追加，`suitableFor` 写清内容类型，决策表会自动同步。
const List<QStyleTheme> qStyleThemes = [
  // ── 家族 A · 杂志风 ──
  QStyleTheme(
    id: 'ink-classic',
    name: '墨水经典',
    family: QStyleFamily.magazine,
    paper: '#f3f1eb',
    ink: '#14130f',
    accent: '#14130f',
    suitableFor: '日记 / 总结 / 文章 / 分享',
  ),
  QStyleTheme(
    id: 'indigo-porcelain',
    name: '靛蓝瓷',
    family: QStyleFamily.magazine,
    paper: '#f2f4f6',
    ink: '#0b2039',
    accent: '#2f5c8f',
    suitableFor: '科技 / 研究 / 深度内容',
  ),
  QStyleTheme(
    id: 'forest-ink',
    name: '森林墨',
    family: QStyleFamily.magazine,
    paper: '#f4f1e7',
    ink: '#1b2f21',
    accent: '#2f6b4e',
    suitableFor: '自然 / 文化 / 非虚构',
  ),
  QStyleTheme(
    id: 'kraft-paper',
    name: '牛皮纸',
    family: QStyleFamily.magazine,
    paper: '#eee0c8',
    ink: '#2b1f14',
    accent: '#94572c',
    suitableFor: '怀旧 / 人文 / 阅读',
  ),
  QStyleTheme(
    id: 'dune',
    name: '沙丘',
    family: QStyleFamily.magazine,
    paper: '#f0e7d4',
    ink: '#201b15',
    accent: '#8d744e',
    suitableFor: '艺术 / 设计 / 画廊感',
  ),
  QStyleTheme(
    id: 'night-ink',
    name: '夜墨（暗色）',
    family: QStyleFamily.magazine,
    paper: '#16140f',
    ink: '#f2efe7',
    accent: '#d7b98c',
    suitableFor: '夜间阅读 / 氛围感',
  ),

  // ── 家族 B · 瑞士风 ──
  QStyleTheme(
    id: 'ikb',
    name: '克莱因蓝',
    family: QStyleFamily.swiss,
    paper: '#fafaf8',
    ink: '#0a0a0a',
    accent: '#002FA7',
    suitableFor: '通用 / AI / 科技 / 方法论',
  ),
  QStyleTheme(
    id: 'lemon',
    name: '柠檬黄',
    family: QStyleFamily.swiss,
    paper: '#fafaf8',
    ink: '#0a0a0a',
    accent: '#FFD500',
    suitableFor: '年轻 / 消费 / 零售',
  ),
  QStyleTheme(
    id: 'lemon-green',
    name: '柠檬绿',
    family: QStyleFamily.swiss,
    paper: '#fafaf8',
    ink: '#0a0a0a',
    accent: '#C5E803',
    suitableFor: '生态 / 健康 / Z 世代',
  ),
  QStyleTheme(
    id: 'safety-orange',
    name: '安全橙',
    family: QStyleFamily.swiss,
    paper: '#fafaf8',
    ink: '#0a0a0a',
    accent: '#FF6B35',
    suitableFor: '警示 / 运动 / 工业',
  ),
  QStyleTheme(
    id: 'graphite',
    name: '石墨（暗色）',
    family: QStyleFamily.swiss,
    paper: '#101010',
    ink: '#f5f5f2',
    accent: '#6d8cff',
    suitableFor: '暗色数据页 / 夜间工具',
  ),
];

/// 校验主题数据：id 唯一 + 关键对比度达标；返回错误列表（空列表表示全部通过）
List<String> qStyleThemeErrors() {
  final errors = <String>[];
  final ids = <String>{};
  for (final theme in qStyleThemes) {
    if (!ids.add(theme.id)) {
      errors.add('主题 id 重复：${theme.id}');
    }
    if (theme.contrastInk < 7) {
      errors.add('${theme.id} 主文字对比度 ${theme.contrastInk.toStringAsFixed(1)}，需 ≥ 7');
    }
    if (theme.contrastText2 < 7) {
      errors.add('${theme.id} 次要文字对比度 ${theme.contrastText2.toStringAsFixed(1)}，需 ≥ 7');
    }
    if (theme.contrastText3 < 4.5) {
      errors.add('${theme.id} 辅助文字对比度 ${theme.contrastText3.toStringAsFixed(1)}，需 ≥ 4.5');
    }
    if (theme.contrastAccentInk < 4.5) {
      errors.add('${theme.id} 强调小字对比度 ${theme.contrastAccentInk.toStringAsFixed(1)}，需 ≥ 4.5');
    }
    // 色块上的文字按「大号粗体」标准执行（WCAG 大字号 AA 为 3:1），留 4.4 余量
    if (theme.contrastAccentOn < 4.4) {
      errors.add('${theme.id} 色块文字对比度 ${theme.contrastAccentOn.toStringAsFixed(1)}，需 ≥ 4.4');
    }
  }
  return errors;
}

/// 按权重 [t] 把 [from] 混向 [to]（t=0 返回 from，t=1 返回 to）
String mixHex(String from, String to, double t) {
  final a = _parseHex(from);
  final b = _parseHex(to);
  return _toHex(List<double>.generate(3, (i) => a[i] * (1 - t) + b[i] * t));
}

/// WCAG 2.x 相对亮度
double luminance(String hex) {
  final channels = _parseHex(hex).map((channel) => channel / 255).toList();
  double linear(double channel) {
    return channel <= 0.03928 ? channel / 12.92 : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * linear(channels[0]) + 0.7152 * linear(channels[1]) + 0.0722 * linear(channels[2]);
}

/// WCAG 2.x 对比度（1~21）
double contrastRatio(String foreground, String background) {
  final a = luminance(foreground);
  final b = luminance(background);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

List<double> _parseHex(String hex) {
  final value = hex.startsWith('#') ? hex.substring(1) : hex;
  return <double>[
    int.parse(value.substring(0, 2), radix: 16).toDouble(),
    int.parse(value.substring(2, 4), radix: 16).toDouble(),
    int.parse(value.substring(4, 6), radix: 16).toDouble(),
  ];
}

String _toHex(List<double> rgb) {
  final buffer = StringBuffer('#');
  for (final channel in rgb) {
    buffer.write(channel.round().clamp(0, 255).toInt().toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

String _darkenUntil(String color, String background, double target) {
  var current = color;
  while (contrastRatio(current, background) < target && current != '#000000') {
    current = _toHex(_parseHex(current).map((channel) => channel * 0.94).toList());
  }
  return current;
}

String _lightenUntil(String color, String background, double target) {
  var current = color;
  while (contrastRatio(current, background) < target && current != '#ffffff') {
    current = _toHex(_parseHex(current).map((channel) => channel + (255 - channel) * 0.06).toList());
  }
  return current;
}
