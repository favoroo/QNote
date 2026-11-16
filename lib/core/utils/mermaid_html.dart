import 'dart:convert';

import 'package:qnote_flutter/core/utils/mermaid_theme.dart';

/// Mermaid 源码 → 完整 HTML 文档（移动端查看器）。
///
/// 预览容器（WebView / iframe srcdoc）的 baseUrl 是伪造子域，**无法引用相对路径资源**，
/// 因此 mermaid 运行时必须以脚本源码形式内联进来（离线可用，不依赖 CDN）。
///
/// 查看器包含固定工具栏（缩放 / 适应宽度 / 100%）、原生双向滚动、双指缩放、
/// 双击切换与主题化状态卡片；颜色全部来自 [MermaidTheme]，不硬编码第二套配色。
///
/// 抽成顶层纯函数便于单测；不接收 BuildContext。
String buildMermaidHtml({
  required String source,
  required String mermaidRuntime,
  required MermaidTheme theme,
  String? notice,
}) {
  // 内联脚本：转义可能提前结束 </script> 的序列（防御性处理）
  final runtime = mermaidRuntime.replaceAll('</script', r'<\/script');
  final sourceLiteral = _jsStringLiteral(source);

  // 配置用 JSON 生成，既是合法 JS 对象，也能让测试直接断言各图型参数
  final mermaidConfig = <String, Object?>{
    'startOnLoad': false,
    'securityLevel': 'strict',
    'theme': 'base',
    'themeVariables': theme.themeVariables,
    'fontFamily': theme.fontFamily,
    'flowchart': <String, Object?>{
      'htmlLabels': true,
      'curve': 'basis',
      'useMaxWidth': false,
      'padding': 12,
      'nodeSpacing': 36,
      'rankSpacing': 44,
    },
    'sequence': <String, Object?>{
      'useMaxWidth': false,
      'mirrorActors': false,
      'wrap': true,
      'width': 120,
      'height': 44,
      'actorMargin': 40,
      'messageMargin': 26,
      'actorFontSize': 14,
      'messageFontSize': 13,
      'noteFontSize': 13,
      'diagramMarginX': 16,
      'diagramMarginY': 16,
    },
    'gantt': <String, Object?>{
      'useMaxWidth': false,
      // Mermaid 11 的 gantt 在 useMaxWidth:false 时以父容器 offsetWidth 作为
      // viewBox 宽度，而离屏渲染容器宽度为 0；显式给自然宽度，避免整图不可见。
      'useWidth': 1000,
      'fontSize': 14,
      'sectionFontSize': 14,
      'barHeight': 34,
      'barGap': 8,
      'topPadding': 50,
      'leftPadding': 150,
      'gridLineStartPadding': 45,
      'numberSectionStyles': 4,
      // 窄屏下每天一个刻度会糊成一团，隔天显示并缩短日期
      'tickInterval': '2day',
      'axisFormat': '%m-%d',
    },
    'mindmap': <String, Object?>{'useMaxWidth': false, 'padding': 14, 'maxNodeWidth': 170},
    // 其它图型统一保留自然尺寸，交给外层滚动容器，避免被压到视口宽度后字号过小
    'pie': <String, Object?>{'useMaxWidth': false},
    'state': <String, Object?>{'useMaxWidth': false},
    'class': <String, Object?>{'useMaxWidth': false},
    'er': <String, Object?>{'useMaxWidth': false},
    'journey': <String, Object?>{'useMaxWidth': false},
    'timeline': <String, Object?>{'useMaxWidth': false},
    'quadrantChart': <String, Object?>{'useMaxWidth': false},
    'requirement': <String, Object?>{'useMaxWidth': false},
    'gitGraph': <String, Object?>{'useMaxWidth': false},
  };
  final configJson = jsonEncode(mermaidConfig);

  final buffer = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="zh-CN">')
    ..writeln('<head>')
    ..writeln('<meta charset="utf-8">')
    ..writeln(
      '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, '
      'user-scalable=no, viewport-fit=cover">',
    )
    ..writeln('<style>')
    ..writeln(':root{${theme.cssDeclarations}}')
    ..writeln(_baseCss)
    ..writeln('</style>')
    ..writeln('</head>')
    ..writeln('<body>')
    ..writeln('<div id="toolbar" role="toolbar" aria-label="图表缩放工具">')
    ..writeln('<button type="button" id="zoom-out" aria-label="缩小">−</button>')
    ..writeln('<span id="zoom-label" aria-live="polite">100%</span>')
    ..writeln('<button type="button" id="zoom-in" aria-label="放大">＋</button>')
    ..writeln('<span class="toolbar-spacer"></span>')
    ..writeln('<button type="button" id="zoom-fit">适应宽度</button>')
    ..writeln('<button type="button" id="zoom-reset">100%</button>')
    ..writeln('</div>');
  if (notice != null && notice.trim().isNotEmpty) {
    buffer
      ..writeln('<div id="notice" role="status">')
      ..writeln('<span class="notice-mark" aria-hidden="true">i</span>')
      ..writeln('<span class="notice-text">${_escapeHtml(notice.trim())}</span>')
      ..writeln('</div>');
  }
  buffer
    ..writeln('<div id="stage">')
    ..writeln('<div id="scroll">')
    ..writeln('<div id="diagram" class="is-state">')
    ..writeln('<div class="state" role="status">')
    ..writeln('<span class="spinner" aria-hidden="true"></span>')
    ..writeln('<span class="state-message">正在渲染…</span>')
    ..writeln('</div>')
    ..writeln('</div>')
    ..writeln('</div>')
    ..writeln('<div id="hint" role="status">双指缩放 · 横向滑动查看</div>')
    ..writeln('</div>')
    ..writeln('<script>$runtime</script>')
    ..writeln('<script>')
    ..writeln('(function(){')
    ..writeln('"use strict";')
    ..writeln('var src = $sourceLiteral;')
    ..writeln('var config = $configJson;')
    ..writeln(_scriptBody)
    ..writeln('})();')
    ..writeln('</script>')
    ..writeln('</body>')
    ..writeln('</html>');
  return buffer.toString();
}

/// 把任意文本编成 JS 字符串字面量，并规避 `</script>` 提前闭合与 U+2028/2029 解析歧义
String _jsStringLiteral(String value) {
  var encoded = jsonEncode(value);
  encoded = encoded.replaceAll('</', r'<\/');
  encoded = encoded.replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
  return encoded;
}

/// HTML 文本转义（仅用于提示条等纯文本节点）
String _escapeHtml(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// 查看器外壳样式：surface 工具条 + 实心主色提示条 + 扁平状态卡片。
///
/// 视觉遵循瑞士海报风：单一高饱和主色锚点、1px 发丝线、拉伸的字号对比，
/// 不使用阴影/渐变；所有颜色都来自 `--mmd-*` 主题变量，深浅色共用同一套结构。
///
/// 注意 `#diagram` 使用 `width:max-content;min-width:100%`，不做无条件 flex 居中；
/// 只有内容比容器窄时才通过 `.is-narrow` 加自动外边距居中，超宽内容始终从最左侧开始。
const String _baseCss = r'''
*{box-sizing:border-box;}
html,body{height:100%;margin:0;padding:0;background:transparent;-webkit-text-size-adjust:100%;}
body{display:flex;flex-direction:column;overflow:hidden;color:var(--mmd-on-surface);font-family:var(--mmd-font);font-size:14px;}
/* 顶部工具条：surface 底 + 底部 1px 发丝线；hover/active 直接铺实心主色 */
#toolbar{flex:0 0 auto;display:flex;align-items:center;gap:6px;min-height:46px;padding:5px 12px;background:var(--mmd-surface);border-bottom:1px solid var(--mmd-border);overflow-x:auto;overflow-y:hidden;-webkit-overflow-scrolling:touch;scrollbar-width:none;}
#toolbar::-webkit-scrollbar{display:none;}
#toolbar button{appearance:none;-webkit-appearance:none;flex:0 0 auto;height:34px;min-width:34px;padding:0 12px;border-radius:8px;border:1px solid var(--mmd-border);background:transparent;color:var(--mmd-on-surface);font:inherit;font-size:12px;font-weight:600;line-height:1;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;-webkit-tap-highlight-color:transparent;transition:background-color .12s ease,color .12s ease,border-color .12s ease;}
#toolbar button:active{background:var(--mmd-pressed);border-color:var(--mmd-pressed);color:var(--mmd-on-primary);}
#toolbar button:focus-visible{outline:2px solid var(--mmd-primary);outline-offset:2px;}
/* 适应按钮默认即实心主色：选择器必须压过上面 #toolbar button 的透明底（同为 id 但多一个 type） */
#toolbar button#zoom-fit{background:var(--mmd-primary);border-color:var(--mmd-primary);color:var(--mmd-on-primary);}
#zoom-label{flex:0 0 auto;min-width:48px;text-align:center;font-size:13px;font-weight:600;color:var(--mmd-primary);font-variant-numeric:tabular-nums;letter-spacing:.01em;}
.toolbar-spacer{flex:1 1 auto;min-width:2px;}
/* 提示条：整条实心主色块 + onPrimary 文字，多行自动换行 */
#notice{flex:0 0 auto;display:flex;align-items:flex-start;gap:10px;padding:10px 14px;background:var(--mmd-primary);border-bottom:1px solid var(--mmd-border);color:var(--mmd-on-primary);font-size:12px;font-weight:500;line-height:1.55;}
#notice .notice-mark{flex:0 0 auto;width:18px;height:18px;margin-top:1px;border-radius:50%;border:1.5px solid var(--mmd-on-primary);background:transparent;color:var(--mmd-on-primary);font-size:11px;font-weight:700;display:inline-flex;align-items:center;justify-content:center;}
#notice .notice-text{min-width:0;word-break:break-word;overflow-wrap:anywhere;}
#stage{position:relative;flex:1 1 auto;min-height:0;}
#scroll{position:absolute;inset:0;overflow:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;touch-action:pan-x pan-y;padding:14px;}
#scroll::-webkit-scrollbar{width:4px;height:4px;}
#scroll::-webkit-scrollbar-thumb{background:var(--mmd-border);border-radius:2px;}
#diagram{width:max-content;min-width:100%;}
#diagram svg{display:block;max-width:none !important;height:auto;margin:0;}
#diagram.is-narrow svg{margin-left:auto;margin-right:auto;}
#diagram.is-state{width:100%;display:flex;justify-content:center;align-items:flex-start;padding:28px 0 0;}
#diagram .edgeLabel,#diagram .edgeLabel span,#diagram .edgeLabel div{font-size:12px !important;}
/* 连线标签落在 surface 上，统一回正文色，避免被节点前景色带偏 */
#diagram .edgeLabel,#diagram .edgeLabel span,#diagram .edgeLabel div,#diagram .edgeLabel p{color:var(--mmd-on-surface) !important;}
#diagram .edgeLabel span,#diagram .labelBkg{background-color:var(--mmd-surface) !important;}
#diagram .edgeLabel .label rect{fill:var(--mmd-surface) !important;}
#diagram .nodeLabel{color:var(--mmd-on-primary) !important;}
/* 脑图：实心色块节点，去掉描边与粗连线，只留 1px 发丝连接 */
#diagram .mindmap-node .node-bkg{stroke:none !important;}
#diagram .mindmap-node.section-root .node-bkg{fill:var(--mmd-primary) !important;}
#diagram .mindmap-node.section-root text{fill:var(--mmd-on-primary) !important;}
#diagram .mindmap-node line{display:none !important;}
#diagram .mindmap-edges path,#diagram .mindmap-edges line{stroke:var(--mmd-border) !important;stroke-width:1px !important;}
/* ER：表头实心主色块，属性行用中性表面 + 发丝线，关系标签用第三色实心块 */
#diagram .entityBox{fill:var(--mmd-primary) !important;}
#diagram .entityBox + text.entityLabel{fill:var(--mmd-on-primary) !important;font-weight:600 !important;}
#diagram .attributeBoxOdd,#diagram .attributeBoxEven{stroke:var(--mmd-border) !important;stroke-width:1px !important;}
#diagram .relationshipLabelBox{fill:var(--mmd-tertiary) !important;opacity:1 !important;}
#diagram text.relationshipLabel{fill:var(--mmd-on-tertiary) !important;font-weight:600 !important;}
/* class：实心主色节点上的标题/成员文字保持可读 */
#diagram g.classGroup text,#diagram .classGroup text,#diagram .classLabel .label{fill:var(--mmd-on-primary) !important;}
/* gantt 兜底：active/done 任务条内文字跟随各自实心底色 */
#diagram .activeText0,#diagram .activeText1,#diagram .activeText2,#diagram .activeText3{fill:var(--mmd-on-tertiary) !important;}
#diagram .activeCritText0,#diagram .activeCritText1,#diagram .activeCritText2,#diagram .activeCritText3{fill:var(--mmd-on-tertiary) !important;}
#diagram .doneText0,#diagram .doneText1,#diagram .doneText2,#diagram .doneText3{fill:var(--mmd-on-surface) !important;}
#diagram .doneCritText0,#diagram .doneCritText1,#diagram .doneCritText2,#diagram .doneCritText3{fill:var(--mmd-on-surface) !important;}
/* Mermaid 全局 tooltip 落在 body 上，改成表面卡片，避免第三色实心块上文字失真 */
div.mermaidTooltip{background:var(--mmd-surface-container) !important;color:var(--mmd-on-surface) !important;border:1px solid var(--mmd-border) !important;border-radius:8px !important;}
/* 状态卡：无阴影、hairline 边；错误态用 error 实心标题条 + onError 文字 */
.state-card{width:min(100%,560px);max-width:100%;border:1px solid var(--mmd-border);background:var(--mmd-surface);border-radius:12px;overflow:hidden;display:flex;flex-direction:column;text-align:left;}
.state-head{display:flex;align-items:center;gap:10px;padding:12px 16px;}
.state-card:not(.error) .state-head{flex-direction:column;align-items:center;text-align:center;padding:22px 18px 0;gap:12px;}
.state-card.error .state-head{background:var(--mmd-error);color:var(--mmd-on-error);}
.state-icon{width:44px;height:44px;border-radius:50%;background:var(--mmd-primary);color:var(--mmd-on-primary);display:flex;align-items:center;justify-content:center;flex:0 0 auto;}
.state-card.error .state-icon{width:28px;height:28px;border-radius:8px;background:var(--mmd-on-error);color:var(--mmd-error);}
.state-title{font-size:15px;font-weight:700;line-height:1.35;letter-spacing:.01em;color:var(--mmd-on-surface);}
.state-card.error .state-title{color:var(--mmd-on-error);}
.state-body{display:flex;flex-direction:column;gap:10px;padding:14px 16px 16px;}
.state-card:not(.error) .state-body{align-items:center;text-align:center;padding:14px 18px 20px;}
.state-message{margin:0;font-size:12.5px;line-height:1.6;color:var(--mmd-on-surface);max-width:100%;word-break:break-word;}
.state-card:not(.error) .state-message{color:var(--mmd-on-surface-variant);font-size:12px;line-height:1.6;}
.state-detail{width:100%;margin:0;padding:10px 12px;border-radius:8px;background:var(--mmd-surface-container-low);border:1px solid var(--mmd-border);color:var(--mmd-on-surface);font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11.5px;line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere;text-align:left;max-height:42vh;overflow:auto;user-select:text;-webkit-user-select:text;}
.state-hint{font-size:11px;line-height:1.5;color:var(--mmd-on-surface-variant);letter-spacing:.01em;}
.state{display:flex;flex-direction:column;align-items:center;gap:12px;color:var(--mmd-on-surface-variant);text-align:center;}
.state .state-message{font-size:13px;font-weight:500;letter-spacing:.02em;color:var(--mmd-on-surface-variant);}
.spinner{width:24px;height:24px;border-radius:50%;border:2px solid var(--mmd-track);border-top-color:var(--mmd-primary);animation:mmd-spin .8s linear infinite;}
#hint{position:absolute;left:50%;bottom:18px;transform:translateX(-50%);max-width:calc(100% - 28px);padding:7px 14px;border-radius:999px;background:var(--mmd-surface-container-high);border:1px solid var(--mmd-border);color:var(--mmd-on-surface-variant);font-size:12px;line-height:1.4;white-space:nowrap;pointer-events:none;opacity:0;animation:mmd-hint-in .25s ease .15s forwards,mmd-hint-out .45s ease 2.4s forwards;}
@keyframes mmd-spin{to{transform:rotate(360deg);}}
@keyframes mmd-hint-in{to{opacity:.96;}}
@keyframes mmd-hint-out{to{opacity:0;visibility:hidden;}}
@media (hover:hover){
#toolbar button:hover{background:var(--mmd-primary);border-color:var(--mmd-primary);color:var(--mmd-on-primary);}
}
@media (prefers-reduced-motion:reduce){.spinner{animation-duration:1.8s;}#toolbar button{transition:none;}}
''';

/// 查看器交互脚本：缩放/双击/双指捏合/Ctrl+滚轮 + 主题化状态。
///
/// 缩放只改 SVG 的 css 宽高（baseW * zoom），平移交给浏览器原生滚动；
/// 不使用 transform 叠加滚动，避免 WebView 中滚动边界与命中坐标错乱。
const String _scriptBody = r'''
var diagram = document.getElementById("diagram");
var scroll = document.getElementById("scroll");
var zoomLabel = document.getElementById("zoom-label");
var hint = document.getElementById("hint");
var svg = null;
var baseW = 0;
var baseH = 0;
var zoom = 1;
var MIN_ZOOM = 0.4;
var MAX_ZOOM = 4.0;
var FIT_MAX = 2.0;
var PADDING = 14;
var pinchDistance = 0;
var pinching = false;
var suppressTap = false;
var tapMoved = false;
var tapStartX = 0;
var tapStartY = 0;
var lastTapAt = 0;
var lastTapX = 0;
var lastTapY = 0;
var lastToggleAt = 0;

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function touchDistance(a, b) {
  var dx = a.clientX - b.clientX;
  var dy = a.clientY - b.clientY;
  return Math.sqrt(dx * dx + dy * dy);
}

function touchMidpoint(a, b) {
  return { x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
}

function setZoomLabel() {
  zoomLabel.textContent = Math.round(zoom * 100) + "%";
}

function availableWidth() {
  return Math.max(0, scroll.clientWidth - PADDING * 2);
}

function clearChildren(element) {
  while (element.firstChild) {
    element.removeChild(element.firstChild);
  }
}

function stateIcon(kind) {
  var open = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" '
    + 'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">';
  if (kind === "error") {
    return open + '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v5.5"/><path d="M12 16.6v.1"/></svg>';
  }
  if (kind === "empty") {
    return open + '<rect x="4" y="4.5" width="6" height="5" rx="1.5"/>'
      + '<rect x="14" y="14.5" width="6" height="5" rx="1.5"/>'
      + '<path d="M10 7h2.5A1.5 1.5 0 0 1 14 8.5V14.5"/>'
      + '<path d="M7 9.5V13a1.5 1.5 0 0 0 1.5 1.5H14"/></svg>';
  }
  return open + '<path d="M9 7 4.5 12 9 17"/><path d="m15 7 4.5 5L15 17"/></svg>';
}

function cleanupMermaidArtifacts() {
  var children = Array.prototype.slice.call(document.body.children);
  for (var i = 0; i < children.length; i++) {
    var element = children[i];
    var id = element.id || "";
    if (id === "qnote-mermaid-diagram" || id === "dqnote-mermaid-diagram") {
      element.parentNode.removeChild(element);
      continue;
    }
    // 除渲染失败的炸弹 SVG 外，Mermaid 也可能留下带错误文案的临时容器。
    if (element.tagName === "DIV" && element.id !== "stage" && element.id !== "toolbar"
      && /Syntax error in text/.test(element.textContent || "")) {
      element.parentNode.removeChild(element);
    }
  }
}

function showState(kind, title, message, detail, footHint) {
  cleanupMermaidArtifacts();
  svg = null;
  zoom = 1;
  clearChildren(diagram);
  diagram.classList.add("is-state");
  scroll.scrollLeft = 0;
  scroll.scrollTop = 0;
  var card = document.createElement("div");
  card.className = "state-card" + (kind === "error" ? " error" : "");
  // 标题条与正文分区：错误态整条铺实心 error 色，正文保留 surface 底。
  var head = document.createElement("div");
  head.className = "state-head";
  var icon = document.createElement("div");
  icon.className = "state-icon";
  icon.innerHTML = stateIcon(kind);
  head.appendChild(icon);
  var titleEl = document.createElement("div");
  titleEl.className = "state-title";
  titleEl.textContent = title;
  head.appendChild(titleEl);
  card.appendChild(head);
  var body = document.createElement("div");
  body.className = "state-body";
  if (message) {
    var messageEl = document.createElement("p");
    messageEl.className = "state-message";
    messageEl.textContent = message;
    body.appendChild(messageEl);
  }
  if (detail) {
    var detailEl = document.createElement("pre");
    detailEl.className = "state-detail";
    detailEl.textContent = detail;
    body.appendChild(detailEl);
  }
  if (footHint) {
    var hintEl = document.createElement("div");
    hintEl.className = "state-hint";
    hintEl.textContent = footHint;
    body.appendChild(hintEl);
  }
  card.appendChild(body);
  diagram.appendChild(card);
  setZoomLabel();
}

function errorText(err) {
  var message = err && (err.message || err.str || err);
  if (message === null || typeof message === "undefined") {
    return "Mermaid 渲染失败";
  }
  if (typeof message !== "string") {
    try {
      message = JSON.stringify(message);
    } catch (ignored) {
      message = String(message);
    }
  }
  return message;
}

function showError(err) {
  var raw = errorText(err);
  var entityHint = erDiagramEntityHint(src);
  if (entityHint) {
    showState(
      "error",
      "关系图标识符不兼容",
      entityHint,
      "原始错误信息：\n" + raw,
      "可点右上角切到源码检查"
    );
    return;
  }
  showState(
    "error",
    "图表渲染失败",
    "Mermaid 无法解析当前源码，请检查语法。",
    "原始错误信息：\n" + raw,
    "可点右上角切到源码检查"
  );
}

// Mermaid 11.4.1 的 erDiagram 实体名只接受英文/数字/下划线；中文实体名或
// 中文别名（USER["用户"]）会直接语法报错。这里做一次轻量诊断，给出可操作建议。
function erDiagramEntityHint(source) {
  var hint = "Mermaid 关系图的实体名、字段类型和字段名只支持英文/数字/下划线，"
    + "中文会直接导致语法错误。中文请放进引号包裹的关系标签或字段注释，"
    + "例如 USER ||--o{ ORDER : \"下单\"、string nickname \"昵称\"。"
    + "可让小Q 按这个规范修正源码，或改用流程图/思维导图。";
  var text = source.replace(/^\uFEFF/, "").trim();
  if (!/^erDiagram\b/i.test(text)) {
    return "";
  }
  var lines = text.split(/\r?\n/);
  var attributeDepth = 0;
  for (var i = 1; i < lines.length; i++) {
    var line = lines[i].replace(/%%.*$/, "").trim();
    if (!line) {
      continue;
    }
    if (/^(title|accTitle|accDescr|direction)\b/i.test(line)) {
      continue;
    }
    if (attributeDepth > 0) {
      // 字段块内部：中文注释合法，但去掉引号内容与 PK/FK/UK 后，
      // 类型/字段名仍有非 ASCII 就是语法错误。
      var attributeText = line.replace(/"[^"]*"/g, "").replace(/'[^']*'/g, "");
      attributeText = attributeText.replace(/\b(PK|FK|UK)\b/gi, "");
      if (/[^\x00-\x7F]/.test(attributeText)) {
        return hint;
      }
      attributeDepth = Math.max(0, attributeDepth + countChar(line, "{") - countChar(line, "}"));
      continue;
    }
    // 关系基数里也有 `o{` / `|{`，它们不是属性块，不能据此进入属性解析。
    var blockStart = findAttributeBlockStart(line);
    var entityPart = (blockStart >= 0 ? line.slice(0, blockStart) : line).split(":")[0];
    // 关系标签在冒号之后，已经排除；此时实体部分任何非 ASCII 字符都意味着
    // 中文实体名或不受支持的中文别名（USER["用户"]）。
    if (/[^\x00-\x7F]/.test(entityPart)) {
      return hint;
    }
    if (blockStart >= 0) {
      var block = line.slice(blockStart);
      attributeDepth = Math.max(0, attributeDepth + countChar(block, "{") - countChar(block, "}"));
    }
  }
  return "";
}

function countChar(text, character) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.charAt(i) === character) {
      count++;
    }
  }
  return count;
}

function findAttributeBlockStart(line) {
  var index = line.indexOf("{");
  while (index >= 0) {
    var previous = index > 0 ? line.charAt(index - 1) : "";
    // 基数符号 `o{` / `|{` 不是实体属性块
    if (previous !== "o" && previous !== "|") {
      return index;
    }
    index = line.indexOf("{", index + 1);
  }
  return -1;
}

function showEmpty() {
  showState("empty", "暂无可预览图表", "当前 Mermaid 源码为空，点右上角查看源码并添加内容。", null, null);
}

function showRuntimeMissing() {
  showState("fallback", "预览组件未就绪", "Mermaid 运行库未加载，暂以源码显示。", src, "可点右上角切到源码检查");
}

function measureBase() {
  var viewBox = svg.viewBox && svg.viewBox.baseVal;
  var width = viewBox && viewBox.width > 0 ? viewBox.width : 0;
  var height = viewBox && viewBox.height > 0 ? viewBox.height : 0;
  if (!(width > 0 && height > 0)) {
    var previousWidth = svg.style.width;
    var previousHeight = svg.style.height;
    var previousMaxWidth = svg.style.maxWidth;
    svg.style.width = "";
    svg.style.height = "";
    svg.style.maxWidth = "none";
    var rect = svg.getBoundingClientRect();
    width = rect.width;
    height = rect.height;
    svg.style.width = previousWidth;
    svg.style.height = previousHeight;
    svg.style.maxWidth = previousMaxWidth;
  }
  return { width: width, height: height };
}

function applySize() {
  svg.style.width = (baseW * zoom) + "px";
  svg.style.height = (baseH * zoom) + "px";
  svg.style.maxWidth = "none";
  diagram.classList.toggle("is-narrow", baseW * zoom < availableWidth() - 1);
}

function initialZoom() {
  // 初始一律 100%：优先保证字号可读，也避免测量误差把图放大后右侧被裁；
  // 小图想铺满宽度时点工具栏「适应宽度」即可。
  return 1;
}

function fitZoomValue() {
  var available = availableWidth();
  if (available <= 0 || baseW <= 0) {
    return 1;
  }
  return clamp(available / baseW, MIN_ZOOM, FIT_MAX);
}

function zoomTo(nextZoom, anchorX, anchorY) {
  if (!svg || baseW <= 0) {
    return;
  }
  nextZoom = clamp(nextZoom, MIN_ZOOM, MAX_ZOOM);
  if (Math.abs(nextZoom - zoom) < 0.0005) {
    setZoomLabel();
    return;
  }
  var scrollRect = scroll.getBoundingClientRect();
  var svgRect = svg.getBoundingClientRect();
  var hasAnchor = typeof anchorX === "number" && typeof anchorY === "number";
  var anchorClientX = hasAnchor ? anchorX : scrollRect.left + scroll.clientWidth / 2;
  var anchorClientY = hasAnchor ? anchorY : scrollRect.top + scroll.clientHeight / 2;
  // 捏合中心对应的 SVG 基础坐标：缩放前后保持该点停留在同一屏幕位置。
  var baseX = (anchorClientX - svgRect.left) / zoom;
  var baseY = (anchorClientY - svgRect.top) / zoom;
  zoom = nextZoom;
  applySize();
  var nextRect = svg.getBoundingClientRect();
  var originX = scroll.scrollLeft + nextRect.left - scrollRect.left;
  var originY = scroll.scrollTop + nextRect.top - scrollRect.top;
  scroll.scrollLeft = originX + baseX * zoom - (anchorClientX - scrollRect.left);
  scroll.scrollTop = originY + baseY * zoom - (anchorClientY - scrollRect.top);
  setZoomLabel();
}

function zoomAtCenter(nextZoom) {
  zoomTo(nextZoom, null, null);
}

function toggleFitAndActual() {
  if (!svg) {
    return;
  }
  if (Math.abs(zoom - 1) < 0.02) {
    zoomAtCenter(fitZoomValue());
  } else {
    zoomAtCenter(1);
  }
}

function handleTap(clientX, clientY) {
  var now = Date.now();
  var isDoubleTap = now - lastTapAt < 320
    && Math.abs(clientX - lastTapX) < 30
    && Math.abs(clientY - lastTapY) < 30;
  if (isDoubleTap) {
    lastTapAt = 0;
    lastToggleAt = now;
    toggleFitAndActual();
    return;
  }
  lastTapAt = now;
  lastTapX = clientX;
  lastTapY = clientY;
}

document.getElementById("zoom-out").addEventListener("click", function () {
  zoomAtCenter(zoom / 1.2);
});
document.getElementById("zoom-in").addEventListener("click", function () {
  zoomAtCenter(zoom * 1.2);
});
document.getElementById("zoom-fit").addEventListener("click", function () {
  zoomAtCenter(fitZoomValue());
});
document.getElementById("zoom-reset").addEventListener("click", function () {
  zoomAtCenter(1);
});

// 桌面端双击切换；移动端由下面的双击检测处理，二者用 lastToggleAt 去重。
scroll.addEventListener("dblclick", function (event) {
  if (Date.now() - lastToggleAt < 600) {
    return;
  }
  event.preventDefault();
  lastToggleAt = Date.now();
  toggleFitAndActual();
});

// Ctrl/⌘ + 滚轮（含触控板捏合）以指针位置为锚点缩放；普通滚轮保持原生滚动。
scroll.addEventListener("wheel", function (event) {
  if (!event.ctrlKey && !event.metaKey) {
    return;
  }
  event.preventDefault();
  zoomTo(zoom * Math.exp(-event.deltaY * 0.01), event.clientX, event.clientY);
}, { passive: false });

// 双指捏合：touchmove 在两指时阻止默认页面缩放，单指不拦截以保留原生滚动。
scroll.addEventListener("touchstart", function (event) {
  if (event.touches.length >= 2) {
    pinching = true;
    suppressTap = true;
    pinchDistance = touchDistance(event.touches[0], event.touches[1]);
    if (event.cancelable) {
      event.preventDefault();
    }
  } else if (event.touches.length === 1) {
    tapMoved = false;
    tapStartX = event.touches[0].clientX;
    tapStartY = event.touches[0].clientY;
  }
}, { passive: false });

scroll.addEventListener("touchmove", function (event) {
  if (event.touches.length >= 2) {
    if (event.cancelable) {
      event.preventDefault();
    }
    var distance = touchDistance(event.touches[0], event.touches[1]);
    if (!pinching) {
      pinching = true;
      suppressTap = true;
      pinchDistance = distance;
      return;
    }
    if (pinchDistance <= 0 || distance <= 0) {
      return;
    }
    var midpoint = touchMidpoint(event.touches[0], event.touches[1]);
    zoomTo(zoom * (distance / pinchDistance), midpoint.x, midpoint.y);
    pinchDistance = distance;
    return;
  }
  if (!suppressTap && event.touches.length === 1) {
    var dx = event.touches[0].clientX - tapStartX;
    var dy = event.touches[0].clientY - tapStartY;
    if (dx * dx + dy * dy > 144) {
      tapMoved = true;
    }
  }
}, { passive: false });

scroll.addEventListener("touchend", function (event) {
  if (event.touches.length >= 2) {
    pinchDistance = touchDistance(event.touches[0], event.touches[1]);
    return;
  }
  if (event.touches.length === 1) {
    // 还有一根手指在屏幕上：等待全部抬起，期间不把它当作点击。
    pinching = true;
    pinchDistance = 0;
    return;
  }
  var changed = event.changedTouches && event.changedTouches[0];
  if (!suppressTap && !tapMoved && changed) {
    handleTap(changed.clientX, changed.clientY);
  }
  pinching = false;
  suppressTap = false;
});

scroll.addEventListener("touchcancel", function () {
  pinching = false;
  suppressTap = false;
  pinchDistance = 0;
});

window.addEventListener("resize", function () {
  if (!svg) {
    return;
  }
  applySize();
  setZoomLabel();
});

if (hint) {
  window.setTimeout(function () {
    if (hint && hint.parentNode) {
      hint.parentNode.removeChild(hint);
    }
  }, 3200);
}

function render() {
  if (!src || !src.trim()) {
    showEmpty();
    return;
  }
  if (!window.mermaid) {
    showRuntimeMissing();
    return;
  }
  try {
    mermaid.initialize(config);
    mermaid.render("qnote-mermaid-diagram", src).then(function (result) {
      if (!result || !result.svg) {
        showError(new Error("未生成 SVG"));
        return;
      }
      clearChildren(diagram);
      diagram.classList.remove("is-state");
      diagram.innerHTML = result.svg;
      cleanupMermaidArtifacts();
      svg = diagram.querySelector("svg");
      if (!svg) {
        showError(new Error("未生成 SVG"));
        return;
      }
      if (typeof result.bindFunctions === "function") {
        try {
          result.bindFunctions(diagram);
        } catch (ignored) {
          // 交互绑定失败不影响静态图表展示
        }
      }
      svg.style.maxWidth = "none";
      svg.style.height = "auto";
      var baseSize = measureBase();
      baseW = baseSize.width;
      baseH = baseSize.height;
      if (!(baseW > 0) || !(baseH > 0)) {
        showError(new Error("图表尺寸异常"));
        return;
      }
      zoom = initialZoom();
      applySize();
      scroll.scrollLeft = 0;
      scroll.scrollTop = 0;
      setZoomLabel();
    }).catch(showError);
  } catch (err) {
    showError(err);
  }
}

render();
''';
