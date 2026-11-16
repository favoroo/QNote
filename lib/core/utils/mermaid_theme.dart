import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';

/// Mermaid 预览主题：把 App 的 [ThemeData] 翻译成 Mermaid `themeVariables` 与内联 CSS 变量。
///
/// 图表颜色全部由当前 [ColorScheme] 派生（主色 / 第三色 / 中性色与表面色混合），
/// 保证 Mermaid 与笔记页共用同一套语义色，不再出现默认的紫色节点、亮蓝根节点
/// 或黄绿紫脑图。输出统一为 `#RRGGBB`（背景除外），便于内联进 HTML。
@immutable
class MermaidTheme {
  const MermaidTheme({
    required this.isDark,
    required this.fontFamily,
    required this.fontSize,
    required this.cssVariables,
    required this.themeVariables,
  });

  /// 从当前 Flutter 主题生成 Mermaid 主题。
  ///
  /// [ThemeData] 的 `colorScheme` 提供表面/主色/描边与文字色，`accentInk` 提供
  /// 可读的强调色前景（派生背景下它可能不是 [ColorScheme.primary]）。
  factory MermaidTheme.fromThemeData(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final surface = scheme.surface;
    final onSurface = scheme.onSurface;
    final onSurfaceVariant = scheme.onSurfaceVariant;
    final primary = scheme.primary;
    final onPrimary = scheme.onPrimary;
    final tertiary = scheme.tertiary;
    final onTertiary = scheme.onTertiary;
    final error = scheme.error;
    final onError = scheme.onError;
    final secondary = scheme.secondary;
    final onSecondary = scheme.onSecondary;
    final accent = theme.accentInk;
    final outlineVariant = scheme.outlineVariant;
    const fontFamily = defaultFontFamily;
    const fontSize = defaultFontSize;

    // 发丝线：深色主题的 outlineVariant 带透明度，直接转 #RRGGBB 会丢掉 alpha
    // 变成近黑色；先合成到表面色上，才能得到真正的 1px 细分隔线。
    final hairline = Color.alphaBlend(outlineVariant, surface);
    // 实心主色块上的轮廓：用 onPrimary 低透明度叠在主色上，保留块面边界，
    // 又不会像纯 onPrimary 描边那样抢掉色块本身。
    final onPrimaryLine = Color.alphaBlend(onPrimary.withValues(alpha: 0.3), primary);
    // 按压态：沿主色明度往远离文字色的方向走一档，保持实心色块的对比度。
    final primaryHsl = HSLColor.fromColor(primary);
    final lightInk = onPrimary.computeLuminance() > 0.5;
    final pressed = primaryHsl
        .withLightness((primaryHsl.lightness + (lightInk ? -0.06 : 0.05)).clamp(0.0, 1.0))
        .toColor();
    final lineColor = onSurfaceVariant;
    // 中性层级：ER 属性行、甘特分区、错误详情等非强调区域只用表面色阶。
    final mutedFill = scheme.surfaceContainerLow;
    final raisedFill = scheme.surfaceContainerHigh;

    // 脑图/饼图 12 档色阶：从主色与第三色的色相各取三档近似色相，
    // 交替排布并配两档亮度，保证相邻层级可区分；全部使用高饱和实心填充。
    final primaryHue = HSLColor.fromColor(primary).hue;
    final tertiaryHue = HSLColor.fromColor(tertiary).hue;
    final hues = <double>[
      primaryHue - 18,
      tertiaryHue - 18,
      primaryHue,
      tertiaryHue,
      primaryHue + 18,
      tertiaryHue + 18,
    ].map((hue) => (hue % 360 + 360) % 360).toList(growable: false);
    final scales = <Color>[];
    final scaleLabels = <Color>[];
    for (var i = 0; i < 12; i++) {
      // 前 6 档更深、后 6 档更亮；深浅两套主题都选偏亮区间，黑字可直接达标。
      final lighter = i >= 6;
      final hue = hues[i % hues.length];
      final lightness = isDark ? (lighter ? 0.72 : 0.62) : (lighter ? 0.74 : 0.64);
      final saturation = lighter ? 0.62 : 0.82;
      final fill = HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
      scales.add(fill);
      // 每档单独取黑/白前景，脑图文字在任何色相下都保持 AA 对比度。
      scaleLabels.add(AppContrast.onColor(fill));
    }
    // 饼图只有一种标签色，取对全部 12 档色块「最差对比度」最高的黑/白。
    final pieInk = _bestInkForAll(scales);

    final themeVariables = <String, String>{
      // 通用：关键节点一律主色实心块，文字用 App 计算好的 onPrimary。
      'background': 'transparent',
      'primaryColor': _hex(primary),
      'primaryTextColor': _hex(onPrimary),
      'primaryBorderColor': _hex(onPrimaryLine),
      'secondaryColor': _hex(secondary),
      'secondaryTextColor': _hex(onSecondary),
      'secondaryBorderColor': _hex(hairline),
      'tertiaryColor': _hex(tertiary),
      'tertiaryTextColor': _hex(onTertiary),
      'tertiaryBorderColor': _hex(hairline),
      'lineColor': _hex(lineColor),
      'defaultLinkColor': _hex(lineColor),
      'arrowheadColor': _hex(lineColor),
      'textColor': _hex(onSurface),
      'mainBkg': _hex(primary),
      'nodeBorder': _hex(onPrimaryLine),
      'nodeTextColor': _hex(onPrimary),
      'classText': _hex(onSurface),
      'clusterBkg': _hex(mutedFill),
      'clusterBorder': _hex(hairline),
      'titleColor': _hex(onSurface),
      'edgeLabelBackground': _hex(surface),
      'fontFamily': fontFamily,
      'fontSize': fontSize,
      'errorBkgColor': _hex(error),
      'errorTextColor': _hex(onError),
      // sequence：参与者头部与激活条 = 主色实心；备注 = 第三色实心。
      'actorBkg': _hex(primary),
      'actorBorder': _hex(primary),
      'actorTextColor': _hex(onPrimary),
      'actorLineColor': _hex(lineColor),
      'signalColor': _hex(lineColor),
      'signalTextColor': _hex(onSurface),
      'labelBoxBkgColor': _hex(primary),
      'labelBoxBorderColor': _hex(primary),
      'labelTextColor': _hex(onPrimary),
      'loopTextColor': _hex(onSurface),
      'noteBkgColor': _hex(tertiary),
      'noteTextColor': _hex(onTertiary),
      'noteBorderColor': _hex(tertiary),
      'activationBkgColor': _hex(primary),
      'activationBorderColor': _hex(primary),
      'sequenceNumberColor': _hex(onPrimary),
      // gantt（任务数超限时走 Mermaid 原生兜底）：任务条实心、分区退回表面色阶。
      'sectionBkgColor': _hex(mutedFill),
      'altSectionBkgColor': _hex(surface),
      'sectionBkgColor2': _hex(raisedFill),
      'gridColor': _hex(hairline),
      'taskBkgColor': _hex(primary),
      'taskBorderColor': _hex(primary),
      'taskTextColor': _hex(onPrimary),
      'taskTextOutsideColor': _hex(onSurface),
      'taskTextLightColor': _hex(onPrimary),
      'taskTextDarkColor': _hex(onSurface),
      'taskTextClickableColor': _hex(onPrimary),
      'activeTaskBkgColor': _hex(tertiary),
      'activeTaskBorderColor': _hex(tertiary),
      'doneTaskBkgColor': _hex(raisedFill),
      'doneTaskBorderColor': _hex(hairline),
      // 关键任务用错误色描边标记，底色仍与普通任务一致，保证条内 onPrimary 文字可读。
      'critBkgColor': _hex(primary),
      'critBorderColor': _hex(error),
      'todayLineColor': _hex(accent),
      'sectionFontColor': _hex(onSurface),
      'doneTaskTextColor': _hex(onSurface),
      // class / ER / git / pie 等其它图型的通用兜底。
      'attributeBackgroundColorOdd': _hex(mutedFill),
      'attributeBackgroundColorEven': _hex(surface),
      'commitLabelColor': _hex(onSurface),
      'commitLabelBackground': _hex(raisedFill),
      'pieOpacity': '1',
      'pieStrokeColor': _hex(surface),
      'pieStrokeWidth': '2px',
      'pieOuterStrokeColor': _hex(hairline),
      'pieOuterStrokeWidth': '1px',
      'pieTitleTextColor': _hex(onSurface),
      'pieSectionTextColor': _hex(pieInk),
      'pieLegendTextColor': _hex(onSurface),
      // 脑图根节点：Mermaid 用 git0 / gitBranchLabel0 绘制 .section-root。
      'git0': _hex(primary),
      'gitBranchLabel0': _hex(onPrimary),
      // state / class 兜底：节点实心主色，标签跟随 onPrimary。
      'stateBkg': _hex(primary),
      'stateLabelColor': _hex(onPrimary),
      'transitionColor': _hex(lineColor),
      'transitionLabelColor': _hex(onSurface),
      'specialStateColor': _hex(lineColor),
      'innerEndBackground': _hex(primary),
      'compositeBackground': _hex(surface),
      'compositeTitleBackground': _hex(primary),
      'compositeBorder': _hex(onPrimaryLine),
      'altBackground': _hex(mutedFill),
      'labelBackgroundColor': _hex(surface),
    };

    for (var i = 0; i < 12; i++) {
      themeVariables['cScale$i'] = _hex(scales[i]);
      themeVariables['cScaleLabel$i'] = _hex(scaleLabels[i]);
      themeVariables['pie${i + 1}'] = _hex(scales[i]);
    }
    // git graph 的分支名直接画在分支色上：逐条取同色系可读前景，避免白字落在亮色分支上。
    for (var i = 0; i < 8; i++) {
      final branchFill = i == 0 ? primary : scales[i];
      themeVariables['git$i'] = _hex(branchFill);
      themeVariables['gitBranchLabel$i'] = _hex(i == 0 ? onPrimary : scaleLabels[i]);
    }

    final cssVariables = <String, String>{
      'surface': _hex(surface),
      'surface-container': _hex(scheme.surfaceContainer),
      'surface-container-low': _hex(mutedFill),
      'surface-container-high': _hex(raisedFill),
      'on-surface': _hex(onSurface),
      'on-surface-variant': _hex(onSurfaceVariant),
      // 1px 发丝线：工具条底边、卡片边框、ER 属性行与脑图连线统一使用。
      'border': _hex(hairline),
      'border-soft': _hex(_softMix(surface, outlineVariant, 0.7, maxSaturation: 0.16)),
      'accent': _hex(accent),
      'primary': _hex(primary),
      'on-primary': _hex(onPrimary),
      'tertiary': _hex(tertiary),
      'on-tertiary': _hex(onTertiary),
      'error': _hex(error),
      'on-error': _hex(onError),
      'primary-soft': _hex(_softMix(surface, primary, isDark ? 0.2 : 0.08, maxSaturation: 0.3)),
      'node-border': _hex(onPrimaryLine),
      // 按下态：沿主色明度压一档，保持实心块与 onPrimary 文字的对比度。
      'pressed': _hex(pressed),
      'track': _hex(_softMix(surface, onSurfaceVariant, isDark ? 0.26 : 0.16, maxSaturation: 0.12)),
      'error-soft': _hex(_softMix(surface, error, isDark ? 0.22 : 0.1, maxSaturation: 0.4)),
      'error-surface': _hex(_softMix(surface, error, isDark ? 0.18 : 0.055, maxSaturation: 0.35)),
      'error-border': _hex(_softMix(surface, error, isDark ? 0.42 : 0.32, maxSaturation: 0.45)),
      'code-bg': _hex(mutedFill),
      'font': fontFamily,
    };

    return MermaidTheme(
      isDark: isDark,
      fontFamily: fontFamily,
      fontSize: fontSize,
      cssVariables: cssVariables,
      themeVariables: themeVariables,
    );
  }

  /// 默认字体栈：优先系统 UI 字体与中文无衬线字体。
  static const String defaultFontFamily =
      "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Noto Sans SC', 'Microsoft YaHei', sans-serif";

  /// 正文基准字号；序列图等图型会在配置里单独覆盖。
  static const String defaultFontSize = '15px';

  /// 当前主题是否为深色（部分图型需要按深浅做额外处理时使用）。
  final bool isDark;

  /// 传给 Mermaid `themeVariables.fontFamily` 与内联 CSS 的字体栈。
  final String fontFamily;

  /// 正文基准字号（带 `px`）。
  final String fontSize;

  /// 内联 CSS 自定义属性（键名不带 `--mmd-` 前缀）。
  ///
  /// 工具条、状态卡片等 HTML 外壳也使用这些变量，避免宿主页面硬编码第二套配色。
  final Map<String, String> cssVariables;

  /// Mermaid `theme: 'base'` 使用的完整变量表（含颜色、字体与字号）。
  final Map<String, String> themeVariables;

  /// `:root{}` 内可直接拼接的 CSS 变量声明。
  String get cssDeclarations => cssVariables.entries.map((entry) => '--mmd-${entry.key}:${entry.value}').join(';');
}

/// 把颜色转成 `#RRGGBB`，忽略透明度（Mermaid 变量只接受纯色）。
String _hex(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// 以 [base] 为底、按 [amount] 混入 [tint]，并压低饱和度避免出现刺眼纯色。
Color _softMix(Color base, Color tint, double amount, {double maxSaturation = 0.35}) {
  final mixed = Color.alphaBlend(tint.withValues(alpha: amount), base);
  final hsl = HSLColor.fromColor(mixed);
  if (hsl.saturation <= maxSaturation) {
    return mixed;
  }
  return hsl.withSaturation(maxSaturation).toColor();
}

/// 为整组色块挑选「最差对比度」最高的黑/白前景。
///
/// 饼图的标签色只有一个变量，不能像脑图那样逐档取色；这里比较黑/白在 12 档
/// 实心填充上的最低对比度，保证无论切片落在哪个色阶都保持可读。
Color _bestInkForAll(List<Color> fills) {
  var best = AppContrast.lightInk;
  var bestMinRatio = 0.0;
  for (final ink in const [AppContrast.darkInk, AppContrast.lightInk]) {
    var minRatio = double.infinity;
    for (final fill in fills) {
      final ratio = AppContrast.contrastRatio(fill, ink);
      if (ratio < minRatio) {
        minRatio = ratio;
      }
    }
    if (minRatio > bestMinRatio) {
      best = ink;
      bestMinRatio = minRatio;
    }
  }
  return best;
}
