import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/mermaid_html.dart';
import 'package:qnote_flutter/core/utils/mermaid_theme.dart';

void main() {
  const seed = Color(0xFF005BCB);
  final lightTheme = MermaidTheme.fromThemeData(
    ThemeData(colorSchemeSeed: seed, brightness: Brightness.light, useMaterial3: true),
  );
  final darkTheme = MermaidTheme.fromThemeData(
    ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
  );

  group('buildMermaidHtml', () {
    test('内联运行库、包含源码与渲染容器，且不依赖 CDN', () {
      final html = buildMermaidHtml(
        source: 'flowchart TD\n  A[开始] --> B[结束]',
        mermaidRuntime: 'window.MERMAID_RUNTIME_MARKER=1;',
        theme: lightTheme,
      );
      expect(html, contains('MERMAID_RUNTIME_MARKER'), reason: '运行库应内联');
      expect(html, contains('flowchart TD'), reason: '应包含 Mermaid 源码');
      expect(html, contains('id="diagram"'));
      expect(html, contains('mermaid.render'));
      expect(html.contains('cdn.jsdelivr.net'), isFalse, reason: '必须离线可用，不得引用 CDN');
      expect(html.contains('http://'), isFalse);
      expect(html.contains('https://'), isFalse);
    });

    test('使用 App 主题生成的 base 主题变量，不再硬编码 dark/default 两套色', () {
      final html = buildMermaidHtml(source: 'graph TD;A-->B;', mermaidRuntime: 'x', theme: lightTheme);
      expect(html, contains('"theme":"base"'));
      expect(html, contains('"themeVariables":{'));
      expect(html, contains(lightTheme.themeVariables['primaryColor']));
      expect(html, contains(lightTheme.themeVariables['cScale0']));
      expect(html, contains('PingFang SC'));
      expect(html, contains('"fontSize":"15px"'));
      expect(html, isNot(contains('theme: "default"')));
      expect(html, isNot(contains('theme: "dark"')));
      // 工具条与状态卡也使用同一套主题变量，不出现旧版错误红
      expect(html, contains('--mmd-accent:#'));
      expect(html, contains('--mmd-error-border:#'));
      expect(html, isNot(contains('#c0392b')));
    });

    test('包含固定工具栏与缩放/平移脚本', () {
      final html = buildMermaidHtml(source: 'graph TD;A-->B;', mermaidRuntime: 'x', theme: lightTheme);
      expect(html, contains('id="toolbar"'));
      expect(html, contains('id="zoom-out"'));
      expect(html, contains('id="zoom-in"'));
      expect(html, contains('id="zoom-fit"'));
      expect(html, contains('id="zoom-reset"'));
      expect(html, contains('id="zoom-label"'));
      expect(html, contains('MIN_ZOOM = 0.4'));
      expect(html, contains('MAX_ZOOM = 4.0'));
      expect(html, contains('touchmove'));
      expect(html, contains('passive: false'));
      expect(html, contains('dblclick'));
      expect(html, contains('ctrlKey'));
      expect(html, contains('双指缩放 · 横向滑动查看'));
      // 壳 UI 使用 1px 发丝线与实心主色提示条
      expect(html, contains('--mmd-border:#'));
      expect(html, contains('background:var(--mmd-primary);border-bottom:1px solid var(--mmd-border)'));
      expect(
        html,
        contains('#zoom-label{flex:0 0 auto;min-width:48px;text-align:center;font-size:13px;font-weight:600;'),
      );
    });

    test('超宽内容不再被 flex 居中，外层支持双向原生滚动', () {
      final html = buildMermaidHtml(source: 'graph TD;A-->B;', mermaidRuntime: 'x', theme: lightTheme);
      expect(html, contains('width:max-content'));
      expect(html, contains('min-width:100%'));
      expect(html, isNot(contains('#diagram{display:flex;justify-content:center')));
      expect(html, contains('#diagram.is-narrow svg'));
      expect(html, contains('overflow:auto'));
      expect(html, contains('-webkit-overflow-scrolling:touch'));
      expect(html, contains('padding:14px'));
    });

    test('按图型注入 flowchart / sequence / gantt / mindmap 配置', () {
      final html = buildMermaidHtml(source: 'graph TD;A-->B;', mermaidRuntime: 'x', theme: lightTheme);
      expect(html, contains('"flowchart":{'));
      expect(html, contains('"htmlLabels":true'));
      expect(html, contains('"curve":"basis"'));
      expect(html, contains('"nodeSpacing":36'));
      expect(html, contains('"rankSpacing":44'));

      expect(html, contains('"sequence":{'));
      expect(html, contains('"mirrorActors":false'));
      expect(html, contains('"actorMargin":40'));
      expect(html, contains('"messageMargin":26'));
      expect(html, contains('"actorFontSize":14'));
      expect(html, contains('"diagramMarginX":16'));

      expect(html, contains('"gantt":{'));
      expect(html, contains('"useWidth":1000'));
      expect(html, contains('"barHeight":34'));
      expect(html, contains('"leftPadding":150'));
      expect(html, contains('"gridLineStartPadding":45'));
      expect(html, contains('"tickInterval":"2day"'));

      expect(html, contains('"mindmap":{'));
      expect(html, contains('"maxNodeWidth":170'));
      expect(html, contains('"padding":14'));
      // 其它图型也统一关掉 useMaxWidth，保证可滚动
      expect(html, contains('"pie":{"useMaxWidth":false}'));
      expect(html, contains('"state":{"useMaxWidth":false}'));
      expect(html, contains('"class":{"useMaxWidth":false}'));
    });

    test('深色与浅色 HTML 注入的主题变量不同', () {
      final light = buildMermaidHtml(source: 'graph TD;A-->B;', mermaidRuntime: 'x', theme: lightTheme);
      final dark = buildMermaidHtml(source: 'graph TD;A-->B;', mermaidRuntime: 'x', theme: darkTheme);
      expect(light, isNot(equals(dark)));
      // 不声明 color-scheme：深色下声明确实会让浏览器绘制不透明画布，遮住笔记页表面色
      expect(light, isNot(contains('name="color-scheme"')));
      expect(dark, isNot(contains('name="color-scheme"')));
      expect(light, contains(lightTheme.themeVariables['textColor']));
      expect(dark, contains(darkTheme.themeVariables['textColor']));
      expect(light, isNot(contains(darkTheme.themeVariables['textColor'])));
    });

    test('源码含 </script> 时被转义，不提前闭合脚本', () {
      final html = buildMermaidHtml(source: 'A["</script>"]', mermaidRuntime: 'x', theme: lightTheme);
      expect(html.contains(r'<\/script>'), isTrue);
    });

    test('运行库含 </script> 时也被转义', () {
      final html = buildMermaidHtml(
        source: 'graph TD;A-->B;',
        mermaidRuntime: 'window.M="</script>";',
        theme: lightTheme,
      );
      expect(html.contains(r'<\/script>'), isTrue);
      expect(html.contains('window.M="</script>"'), isFalse);
    });

    test('空源码 / 运行库缺失 / 语法错误都有主题化状态提示', () {
      final html = buildMermaidHtml(source: '   ', mermaidRuntime: 'x', theme: lightTheme);
      expect(html, contains('暂无可预览图表'));
      expect(html, contains('预览组件未就绪'));
      expect(html, contains('Mermaid 运行库未加载'));
      expect(html, contains('图表渲染失败'));
      expect(html, contains('可点右上角切到源码检查'));
      expect(html, contains('state-card'));
      expect(html, contains('state-icon'));
      expect(html, contains('state-head'));
      expect(html, contains('state-body'));
      expect(html, contains('正在渲染…'));
      expect(html, contains('spinner'));
      // 清除 Mermaid 默认的炸弹错误 SVG，避免裸浏览器错误盖住主题化卡片
      expect(html, contains('cleanupMermaidArtifacts'));
      expect(html, contains('dqnote-mermaid-diagram'));
      expect(html, contains('Syntax error in text'));
      // 不能用 display:none 提前隐藏 Mermaid 的离屏测量容器，否则文本尺寸会算成 0
      expect(html, isNot(contains('body > #dqnote-mermaid-diagram')));
    });

    test('关系图中文实体名/字段名有针对性诊断，原始错误信息保留在可滚动代码块', () {
      final html = buildMermaidHtml(source: 'erDiagram\n  用户 ||--o{ 订单 : "下单"', mermaidRuntime: 'x', theme: lightTheme);
      expect(html, contains('关系图标识符不兼容'));
      expect(html, contains('实体名、字段类型和字段名只支持英文/数字/下划线'));
      expect(html, contains('中文请放进引号包裹的关系标签或字段注释'));
      expect(html, contains('erDiagramEntityHint'));
      expect(html, contains('原始错误信息：'));
      expect(html, contains('state-detail'));
      expect(html, contains('user-select:text'));
      // 仍使用统一的主题化错误卡片，而不是浏览器默认错误或炸弹 SVG
      expect(html, contains('图表渲染失败'));
      expect(html, contains('state-card'));
    });

    test('ER 预览修复提示条会被渲染并做 HTML 转义', () {
      final html = buildMermaidHtml(
        source: 'erDiagram\n  USER { string name }',
        mermaidRuntime: 'x',
        theme: lightTheme,
        notice: '中文字段名已处理 <test>',
      );
      expect(html, contains('id="notice"'));
      expect(html, contains('中文字段名已处理 &lt;test&gt;'));
      expect(html, isNot(contains('中文字段名已处理 <test>')));
    });
  });
}
