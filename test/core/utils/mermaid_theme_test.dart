import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/mermaid_theme.dart';

void main() {
  const seed = Color(0xFF005BCB);
  final hexPattern = RegExp(r'^#[0-9A-F]{6}$');

  ThemeData buildTheme(Brightness brightness) =>
      ThemeData(colorSchemeSeed: seed, brightness: brightness, useMaterial3: true);

  Color parseHex(String hex) => Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);

  double contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final high = luminanceA > luminanceB ? luminanceA : luminanceB;
    final low = luminanceA > luminanceB ? luminanceB : luminanceA;
    return (high + 0.05) / (low + 0.05);
  }

  group('MermaidTheme.fromThemeData', () {
    test('输出完整的十六进制颜色变量与字体栈', () {
      final theme = MermaidTheme.fromThemeData(buildTheme(Brightness.light));

      const colorKeys = <String>[
        'primaryColor',
        'primaryTextColor',
        'primaryBorderColor',
        'secondaryColor',
        'tertiaryColor',
        'lineColor',
        'textColor',
        'mainBkg',
        'nodeBorder',
        'clusterBkg',
        'clusterBorder',
        'titleColor',
        'edgeLabelBackground',
        'actorBkg',
        'actorBorder',
        'actorTextColor',
        'actorLineColor',
        'signalColor',
        'signalTextColor',
        'labelBoxBkgColor',
        'labelBoxBorderColor',
        'labelTextColor',
        'loopTextColor',
        'noteBkgColor',
        'noteTextColor',
        'noteBorderColor',
        'sectionBkgColor',
        'altSectionBkgColor',
        'gridColor',
        'doneTaskBkgColor',
        'doneTaskBorderColor',
        'activeTaskBkgColor',
        'activeTaskBorderColor',
        'critBkgColor',
        'critBorderColor',
        'taskTextColor',
        'taskTextOutsideColor',
        'todayLineColor',
      ];
      for (final key in colorKeys) {
        expect(theme.themeVariables[key], matches(hexPattern), reason: '$key 应为合法十六进制颜色');
      }
      expect(theme.themeVariables['background'], 'transparent');
      expect(theme.themeVariables['fontFamily'], contains('PingFang SC'));
      expect(theme.themeVariables['fontSize'], '15px');
      expect(theme.cssVariables['surface'], matches(hexPattern));
      expect(theme.cssVariables['error-border'], matches(hexPattern));
      expect(theme.cssDeclarations, contains('--mmd-surface:#'));
    });

    test('脑图 cScale 为高饱和实心色，且每档文字保持正文级对比度', () {
      final theme = MermaidTheme.fromThemeData(buildTheme(Brightness.light));
      const mermaidDefaults = <String>{
        '#ECECFF',
        '#ffffde',
        '#ccccff',
        '#ffffb3',
        '#ffecf8',
        '#b3e5ff',
        '#b2f2bb',
        '#ffd8a8',
        '#d0bfff',
      };
      for (var i = 0; i < 12; i++) {
        final fillHex = theme.themeVariables['cScale$i']!;
        final labelHex = theme.themeVariables['cScaleLabel$i']!;
        expect(fillHex, matches(hexPattern));
        expect(labelHex, matches(hexPattern));
        expect(mermaidDefaults.contains(fillHex.toUpperCase()), isFalse, reason: 'cScale$i 不应使用 Mermaid 默认亮色');
        final fill = parseHex(fillHex);
        expect(HSLColor.fromColor(fill).saturation, greaterThan(0.5), reason: 'cScale$i 应为实心高饱和色块');
        expect(contrastRatio(fill, parseHex(labelHex)), greaterThanOrEqualTo(4.5), reason: 'cScaleLabel$i 应保证正文级对比度');
      }
    });

    test('深色与浅色主题输出不同且都保持透明背景', () {
      final light = MermaidTheme.fromThemeData(buildTheme(Brightness.light));
      final dark = MermaidTheme.fromThemeData(buildTheme(Brightness.dark));

      expect(light.isDark, isFalse);
      expect(dark.isDark, isTrue);
      expect(light.themeVariables['background'], 'transparent');
      expect(dark.themeVariables['background'], 'transparent');
      expect(light.themeVariables['primaryColor'], isNot(dark.themeVariables['primaryColor']));
      expect(light.themeVariables['textColor'], isNot(dark.themeVariables['textColor']));
      expect(light.themeVariables['cScale0'], isNot(dark.themeVariables['cScale0']));
      // 节点主体与 ER 表头都使用主色实心块，不再退回淡底
      for (final theme in [light, dark]) {
        expect(theme.themeVariables['mainBkg'], theme.themeVariables['primaryColor']);
        expect(theme.themeVariables['nodeTextColor'], theme.themeVariables['primaryTextColor']);
        expect(
          contrastRatio(
            parseHex(theme.themeVariables['primaryColor']!),
            parseHex(theme.themeVariables['primaryTextColor']!),
          ),
          greaterThanOrEqualTo(4.5),
          reason: '实心主色块上的文字应保持正文级对比度',
        );
      }
    });

    test('工具条/错误态 CSS 变量覆盖完整', () {
      final theme = MermaidTheme.fromThemeData(buildTheme(Brightness.dark));
      const requiredKeys = <String>[
        'surface',
        'surface-container',
        'surface-container-low',
        'surface-container-high',
        'on-surface',
        'on-surface-variant',
        'border',
        'border-soft',
        'accent',
        'primary',
        'on-primary',
        'tertiary',
        'on-tertiary',
        'primary-soft',
        'node-border',
        'pressed',
        'track',
        'error',
        'on-error',
        'error-soft',
        'error-surface',
        'error-border',
        'code-bg',
      ];
      for (final key in requiredKeys) {
        expect(theme.cssVariables[key], matches(hexPattern), reason: '$key 应为合法十六进制颜色');
      }
      expect(theme.cssVariables['font'], contains('PingFang SC'));
    });

    test('序列图与 ER 的实心色块在深浅主题下都可读', () {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final theme = MermaidTheme.fromThemeData(buildTheme(brightness));
        final vars = theme.themeVariables;

        // 参与者头部：实心主色 + onPrimary 文字
        expect(vars['actorBkg'], vars['primaryColor']);
        expect(vars['actorTextColor'], vars['primaryTextColor']);
        expect(
          contrastRatio(parseHex(vars['actorBkg']!), parseHex(vars['actorTextColor']!)),
          greaterThanOrEqualTo(4.5),
        );
        // 备注：实心第三色 + onTertiary 文字
        expect(
          contrastRatio(parseHex(vars['noteBkgColor']!), parseHex(vars['noteTextColor']!)),
          greaterThanOrEqualTo(4.5),
          reason: 'sequence note 文字应可读',
        );
        // ER 实体表头与属性行：表头实心主色，属性行回到中性表面
        expect(vars['entityBox'], isNull, reason: 'v11.4.1 没有 entityHeader 变量，使用 mainBkg');
        expect(vars['mainBkg'], vars['primaryColor']);
        expect(
          contrastRatio(parseHex(vars['textColor']!), parseHex(vars['attributeBackgroundColorOdd']!)),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(parseHex(vars['textColor']!), parseHex(vars['attributeBackgroundColorEven']!)),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('内置推荐搭配的主题色在深浅主题下仍能自动取到可读文字', () {
      const accents = <Color>[
        Color(0xFF005BCB), // 经典蓝
        Color(0xFFFF6B18), // 蓝橙电波
        Color(0xFFFCEE21), // 夜之城
        Color(0xFF00FF41), // 黑客帝国
        Color(0xFFA6FF4D), // 初号机
        Color(0xFF0ABAB5), // 蒂芙尼
        Color(0xFFA93A90), // 蒸汽波
        Color(0xFFF80004), // 赤焰黑
      ];
      const pairs = <List<String>>[
        ['primaryColor', 'primaryTextColor'],
        ['actorBkg', 'actorTextColor'],
        ['noteBkgColor', 'noteTextColor'],
        ['mainBkg', 'nodeTextColor'],
      ];
      for (final accent in accents) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          final theme = MermaidTheme.fromThemeData(
            ThemeData(colorSchemeSeed: accent, brightness: brightness, useMaterial3: true),
          );
          for (final pair in pairs) {
            expect(
              contrastRatio(parseHex(theme.themeVariables[pair[0]]!), parseHex(theme.themeVariables[pair[1]]!)),
              greaterThanOrEqualTo(4.5),
              reason: '${pair[0]}/${pair[1]} 在 $accent / $brightness 下应保持正文级对比度',
            );
          }
        }
      }
    });
  });
}
