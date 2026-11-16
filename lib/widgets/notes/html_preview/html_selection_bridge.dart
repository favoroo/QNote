/// 网页预览内的「选择探针」。
///
/// 注入到小Q生成的 HTML 预览中，提供两种选择入口：
/// 1. 选中文字：在选区旁浮出「给小Q」按钮，回传选中文字与所在元素；
/// 2. 长按元素（无文字选区时）：高亮元素并浮出「给小Q · `<tag.class>`」，
///    回传 CSS 选择器、outerHTML、渲染文本与视口位置。
///
/// 回传通道按平台自适应：
/// - 移动端 WebView：`window.QNoteHtmlSelection.postMessage(json)`（JS Channel）；
/// - Web 端 iframe：`window.parent.postMessage(json, '*')`，由父页面按 token 过滤。
class HtmlSelectionBridge {
  HtmlSelectionBridge._();

  /// 用于判断脚本是否已注入，避免重复加载时叠加两套探针
  static const String marker = '__qnote_html_selection_script';

  /// 在 HTML 中注入选择探针脚本（已注入则原样返回）。
  ///
  /// [token] 会写进脚本，Web 端回传时随 payload 一并带上，父页面据此忽略
  /// 其他 iframe / 页面发来的无关消息。
  static String prepareHtml(String htmlContent, {required String token}) {
    if (htmlContent.contains(marker)) {
      return htmlContent;
    }
    final safeToken = token.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final script =
        '<script id="$marker">'
        '${selectionScript.replaceAll('__QNOTE_SELECTION_TOKEN__', safeToken)}'
        '</script>';

    // 用最后一个闭合标签而不是第一个：脚本字符串里可能出现 "</body>"
    // 文本，注入到第一个会破坏页面脚本
    final bodyClose = htmlContent.lastIndexOf('</body>');
    if (bodyClose >= 0) {
      return htmlContent.replaceRange(bodyClose, bodyClose, '$script\n');
    }
    final htmlClose = htmlContent.lastIndexOf('</html>');
    if (htmlClose >= 0) {
      return htmlContent.replaceRange(htmlClose, htmlClose, '$script\n');
    }
    return '$htmlContent\n$script';
  }

  /// 探针脚本主体。
  ///
  /// 约束：
  /// - 只用原生 DOM API，不依赖任何第三方库；
  /// - UI 挂在 Shadow DOM 里，避免被页面样式污染，也不污染页面；
  /// - 所有监听器都做异常兜底，单个页面结构异常不能影响网页本身；
  /// - 不拦截正常点击（仅在长按选中元素后短暂吞掉一次 click）。
  static const String selectionScript = r'''
(function () {
  if (window.__qnoteHtmlSelectionInitialized) return;
  window.__qnoteHtmlSelectionInitialized = true;

  var TOKEN = '__QNOTE_SELECTION_TOKEN__';
  var HOST_ID = '__qnote_selection_host__';
  var host = null;
  var root = null;
  var pill = null;
  var pillLabel = null;
  var cancelBtn = null;
  var outline = null;
  var selectedEl = null;
  var mode = null;
  var selectionTimer = null;
  var suppressNextClick = false;
  var suppressClickTimer = null;

  function isOurEvent(e) {
    if (!host) return false;
    try {
      var path = e && e.composedPath ? e.composedPath() : null;
      if (path) {
        for (var i = 0; i < path.length; i++) {
          if (path[i] === host) return true;
        }
      }
    } catch (err) {}
    var target = e && e.target;
    if (!target) return false;
    if (target === host) return true;
    try { return host.contains(target); } catch (err) { return false; }
  }

  function ensureUi() {
    if (host && document.documentElement && document.documentElement.contains(host)) return;
    if (!document.body) return;

    host = document.createElement('div');
    host.id = HOST_ID;
    host.setAttribute('data-qnote-ui', '1');
    host.style.cssText = 'all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483000;pointer-events:none;';
    document.body.appendChild(host);
    root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;

    var style = document.createElement('style');
    style.textContent = [
      ':host{all:initial}',
      '.q-pill{position:fixed;display:none;align-items:center;gap:6px;',
      'padding:7px 12px;border-radius:999px;background:#1f2328;color:#fff;',
      'font:600 13px/1.2 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;',
      'border:1px solid rgba(255,255,255,.16);box-shadow:0 6px 20px rgba(0,0,0,.28);',
      'pointer-events:auto;cursor:pointer;user-select:none;-webkit-user-select:none;',
      'white-space:nowrap;-webkit-tap-highlight-color:transparent;touch-action:manipulation;}',
      '.q-pill:active{transform:scale(.97)}',
      '.q-dot{width:6px;height:6px;border-radius:50%;background:#7bd88f;',
      'box-shadow:0 0 6px rgba(123,216,143,.8);flex:0 0 auto;}',
      '.q-label{max-width:220px;overflow:hidden;text-overflow:ellipsis;}',
      '.q-cancel{display:none;margin-left:2px;padding:2px 7px;border-radius:999px;',
      'background:rgba(255,255,255,.14);color:rgba(255,255,255,.85);font-size:12px;}',
      '.q-outline{position:fixed;display:none;border:2px solid #2f6feb;',
      'background:rgba(47,111,235,.07);border-radius:4px;pointer-events:none;box-sizing:border-box;}'
    ].join('');
    root.appendChild(style);

    outline = document.createElement('div');
    outline.className = 'q-outline';
    root.appendChild(outline);

    pill = document.createElement('div');
    pill.className = 'q-pill';
    pill.setAttribute('role', 'button');
    pill.setAttribute('aria-label', '发送给小Q');
    var dot = document.createElement('span');
    dot.className = 'q-dot';
    pillLabel = document.createElement('span');
    pillLabel.className = 'q-label';
    pillLabel.textContent = '给小Q';
    cancelBtn = document.createElement('span');
    cancelBtn.className = 'q-cancel';
    cancelBtn.setAttribute('role', 'button');
    cancelBtn.setAttribute('aria-label', '取消选择');
    cancelBtn.textContent = '×';
    pill.appendChild(dot);
    pill.appendChild(pillLabel);
    pill.appendChild(cancelBtn);
    root.appendChild(pill);

    pill.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      if (mode === 'element' && selectedEl) {
        var elementInfo = elementPayload(selectedEl, 'element');
        exitElementMode();
        // 与文字选区一致：收起网页内焦点/键盘，让悬浮面板输入框接管
        clearSelectionUi();
        send(elementInfo);
      } else if (mode === 'text') {
        var selectionInfo = selectionPayload();
        clearSelectionUi();
        send(selectionInfo);
      }
    }, true);

    cancelBtn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      exitElementMode();
      clearSelectionUi();
    }, true);

    pill.addEventListener('pointerdown', function (e) { e.stopPropagation(); }, true);
    cancelBtn.addEventListener('pointerdown', function (e) { e.stopPropagation(); }, true);
  }

  function placePill(rect) {
    if (!pill || !rect) return;
    pill.style.display = 'inline-flex';
    var pw = pill.offsetWidth || 92;
    var ph = pill.offsetHeight || 32;
    var vw = window.innerWidth || document.documentElement.clientWidth || 0;
    var vh = window.innerHeight || document.documentElement.clientHeight || 0;
    var cx = rect.left + rect.width / 2;
    var left = Math.min(Math.max(8, cx - pw / 2), Math.max(8, vw - pw - 8));
    var top = rect.top - ph - 10;
    if (top < 8 || rect.top < ph + 18) {
      top = Math.min(rect.bottom + 10, Math.max(8, vh - ph - 8));
    }
    pill.style.left = left + 'px';
    pill.style.top = top + 'px';
  }

  function hidePill() {
    if (pill) pill.style.display = 'none';
  }

  function showOutline(rect) {
    if (!outline || !rect) return;
    var vw = window.innerWidth || document.documentElement.clientWidth || 0;
    var vh = window.innerHeight || document.documentElement.clientHeight || 0;
    var left = Math.max(0, rect.left);
    var top = Math.max(0, rect.top);
    var right = Math.min(vw, rect.right);
    var bottom = Math.min(vh, rect.bottom);
    if (right <= left || bottom <= top) {
      outline.style.display = 'none';
      return;
    }
    outline.style.display = 'block';
    outline.style.left = left + 'px';
    outline.style.top = top + 'px';
    outline.style.width = (right - left) + 'px';
    outline.style.height = (bottom - top) + 'px';
  }

  function hideOutline() {
    if (outline) outline.style.display = 'none';
  }

  function rectInfo(rect) {
    if (!rect) return null;
    return {
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      w: Math.round(rect.width),
      h: Math.round(rect.height)
    };
  }

  function cssEscape(value) {
    try {
      if (window.CSS && CSS.escape) return CSS.escape(value);
    } catch (e) {}
    return String(value).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
  }

  function cssPath(el) {
    if (!el || el.nodeType !== 1) return '';
    if (el.id) return '#' + cssEscape(el.id);
    var parts = [];
    var cur = el;
    var depth = 0;
    while (cur && cur.nodeType === 1 && cur !== document.documentElement && depth < 8) {
      var part = cur.tagName.toLowerCase();
      if (cur.id) {
        parts.unshift('#' + cssEscape(cur.id));
        break;
      }
      var parent = cur.parentElement;
      if (parent) {
        var same = 0;
        var index = 1;
        var children = parent.children || [];
        for (var i = 0; i < children.length; i++) {
          if (children[i].tagName === cur.tagName) {
            same++;
            if (children[i] === cur) index = same;
          }
        }
        if (same > 1) part += ':nth-of-type(' + index + ')';
      }
      parts.unshift(part);
      cur = cur.parentElement;
      depth++;
    }
    return parts.join(' > ');
  }

  function shortLabel(el) {
    if (!el || el.nodeType !== 1) return '元素';
    var label = el.tagName.toLowerCase();
    if (el.id) label += '#' + el.id;
    if (el.classList && el.classList.length) {
      label += '.' + Array.prototype.slice.call(el.classList, 0, 3).join('.');
    }
    return label;
  }

  function ancestorsOf(el) {
    var out = [];
    var cur = el && el.parentElement;
    var depth = 0;
    while (cur && cur !== document.documentElement && depth < 6) {
      out.unshift(shortLabel(cur));
      cur = cur.parentElement;
      depth++;
    }
    return out.join(' > ');
  }

  function clampText(value, max) {
    var text = value == null ? '' : String(value);
    if (text.length > max) return text.slice(0, max) + '…（已截断）';
    return text;
  }

  function elementPayload(el, kind) {
    var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
    var html = '';
    try { html = el.outerHTML || ''; } catch (e) {}
    var classes = [];
    try { classes = Array.prototype.slice.call(el.classList || [], 0, 12); } catch (e) {}
    var text = '';
    try { text = (el.innerText || el.textContent || '').trim(); } catch (e) {}
    return {
      token: TOKEN,
      kind: kind || 'element',
      selector: cssPath(el),
      tag: el.tagName ? el.tagName.toLowerCase() : '',
      id: el.id || '',
      classes: classes,
      text: clampText(text, 3000),
      html: clampText(html, 6000),
      ancestors: ancestorsOf(el),
      rect: rectInfo(rect),
      scroll: {
        x: Math.round(window.pageXOffset || document.documentElement.scrollLeft || 0),
        y: Math.round(window.pageYOffset || document.documentElement.scrollTop || 0)
      },
      viewport: {
        w: Math.round(window.innerWidth || document.documentElement.clientWidth || 0),
        h: Math.round(window.innerHeight || document.documentElement.clientHeight || 0)
      },
      pageTitle: document.title || '',
      url: location.href || ''
    };
  }

  function selectionPayload() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
    var text = sel.toString().replace(/\s+/g, ' ').trim();
    if (!text) return null;
    var range = sel.getRangeAt(0);
    var node = range.commonAncestorContainer;
    var el = node && node.nodeType === 1 ? node : (node && node.parentElement);
    if (!el) return null;
    // 跨段选择时 commonAncestorContainer 可能是 body：退回到选区起点所在元素，
    // 否则会回传整页 HTML，反而干扰小Q定位
    if (el === document.body || el === document.documentElement) {
      var start = range.startContainer;
      el = start && start.nodeType === 1 ? start : (start && start.parentElement) || el;
    }
    var payload = elementPayload(el, 'text');
    payload.text = clampText(text, 3000);
    payload.rect = rectInfo(range.getBoundingClientRect());
    return payload;
  }

  function send(payload) {
    if (!payload) return;
    payload.token = TOKEN;
    var message;
    try { message = JSON.stringify(payload); } catch (e) { return; }
    try {
      if (window.QNoteHtmlSelection && typeof window.QNoteHtmlSelection.postMessage === 'function') {
        window.QNoteHtmlSelection.postMessage(message);
        return;
      }
    } catch (e) {}
    try {
      if (window.parent && window.parent !== window) {
        window.parent.postMessage(message, '*');
      }
    } catch (e) {}
  }

  function clearSelectionUi() {
    mode = null;
    hidePill();
    try {
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();
    } catch (e) {}
    try {
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    } catch (e) {}
  }

  function exitElementMode() {
    selectedEl = null;
    mode = null;
    hideOutline();
    hidePill();
  }

  function enterElementMode(el) {
    if (!el) return;
    ensureUi();
    if (!pill || !outline) return;
    mode = 'element';
    selectedEl = el;
    try {
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();
    } catch (e) {}
    var rect = el.getBoundingClientRect();
    showOutline(rect);
    pillLabel.textContent = '给小Q · ' + shortLabel(el);
    cancelBtn.style.display = 'inline-block';
    placePill(rect);
    // 吞掉长按松手后浏览器补发的一次 click，避免误触页面里的按钮/链接；
    // 长按后若没有产生 click（拖拽/滚动），1.5s 后自动解除，避免误吞后续正常点击
    suppressNextClick = true;
    if (suppressClickTimer) clearTimeout(suppressClickTimer);
    suppressClickTimer = setTimeout(function () {
      suppressNextClick = false;
      suppressClickTimer = null;
    }, 1500);
  }

  function onSelectionChanged() {
    if (mode === 'element') return;
    var payload = selectionPayload();
    if (!payload) {
      if (mode === 'text') {
        mode = null;
        hidePill();
      }
      return;
    }
    ensureUi();
    if (!pill) return;
    mode = 'text';
    cancelBtn.style.display = 'none';
    pillLabel.textContent = '给小Q';
    placePill(payload.rect);
  }

  // ===== 文字选区 =====
  document.addEventListener('selectionchange', function () {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(onSelectionChanged, 180);
  });
  document.addEventListener('mouseup', function () {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(onSelectionChanged, 60);
  });
  document.addEventListener('touchend', function () {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(onSelectionChanged, 120);
  }, { passive: true });

  // 判断按压点是否落在可选中文字上：在文字上时长按交给浏览器原生选区，
  // 避免元素选择抢走「长按选词」；只有卡片留白、图片等非文字区域才进入元素选择。
  // 表单控件与可编辑区域的焦点/长按粘贴属于页面原生交互，不参与元素选择
  function isFormControl(el) {
    try {
      var tag = (el.tagName || '').toLowerCase();
      return tag === 'input' || tag === 'textarea' || tag === 'select' || !!el.isContentEditable;
    } catch (e) {
      return false;
    }
  }

  function pointLooksLikeText(x, y) {
    try {
      var range = null;
      if (document.caretRangeFromPoint) {
        range = document.caretRangeFromPoint(x, y);
      } else if (document.caretPositionFromPoint) {
        var pos = document.caretPositionFromPoint(x, y);
        if (pos && pos.offsetNode) {
          range = document.createRange();
          range.setStart(pos.offsetNode, pos.offset);
          range.collapse(true);
        }
      }
      if (!range) return false;
      var node = range.startContainer;
      if (!node || node.nodeType !== 3 || !(node.textContent || '').trim()) return false;
      var rect = range.getBoundingClientRect();
      // 部分浏览器对折叠 Range 返回零尺寸矩形，此时无法判断距离，按文字处理更稳妥
      if (rect.width === 0 && rect.height === 0) return true;
      var pad = 12;
      return x >= rect.left - pad && x <= rect.right + pad && y >= rect.top - pad && y <= rect.bottom + pad;
    } catch (e) {
      return false;
    }
  }

  // ===== 长按元素（仅在没有文字选区时接管） =====
  var pressTimer = null;
  var pressX = 0;
  var pressY = 0;

  function clearPress() {
    if (pressTimer) {
      clearTimeout(pressTimer);
      pressTimer = null;
    }
  }

  document.addEventListener('pointerdown', function (e) {
    if (isOurEvent(e)) return;
    clearPress();
    pressX = e.clientX;
    pressY = e.clientY;
    pressTimer = setTimeout(function () {
      pressTimer = null;
      try {
        var sel = window.getSelection();
        if (sel && !sel.isCollapsed && sel.toString().trim()) return;
        if (pointLooksLikeText(pressX, pressY)) return;
        var el = document.elementFromPoint(pressX, pressY);
        if (!el || isOurEvent({ target: el })) return;
        if (el === document.documentElement) el = document.body;
        if (!el || el === document.body) return;
        if (isFormControl(el)) return;
        enterElementMode(el);
      } catch (err) {}
    }, 480);
  }, { passive: true, capture: true });

  document.addEventListener('pointermove', function (e) {
    if (!pressTimer) return;
    if (Math.abs(e.clientX - pressX) > 8 || Math.abs(e.clientY - pressY) > 8) {
      clearPress();
    }
  }, { passive: true, capture: true });
  document.addEventListener('pointerup', clearPress, { passive: true, capture: true });
  document.addEventListener('pointercancel', clearPress, { passive: true, capture: true });

  // 元素模式：点其他元素切换选中，点页面空白取消
  document.addEventListener('pointerdown', function (e) {
    if (mode !== 'element') return;
    if (isOurEvent(e)) return;
    var el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === document.documentElement || el === document.body) {
      exitElementMode();
      return;
    }
    setTimeout(function () {
      if (mode === 'element' && el && el.isConnected) enterElementMode(el);
    }, 0);
  }, { passive: true, capture: true });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      exitElementMode();
      clearSelectionUi();
    }
  }, true);

  document.addEventListener('click', function (e) {
    if (!suppressNextClick) return;
    if (isOurEvent(e)) return;
    suppressNextClick = false;
    e.preventDefault();
    e.stopPropagation();
  }, true);

  // 长按链接/图片时浏览器可能弹出原生菜单，元素选择期间一并吞掉
  document.addEventListener('contextmenu', function (e) {
    if (!suppressNextClick || isOurEvent(e)) return;
    e.preventDefault();
    e.stopPropagation();
  }, true);

  // ===== 滚动/尺寸变化时同步高亮与按钮位置 =====
  function reposition() {
    if (mode === 'element' && selectedEl) {
      var rect = selectedEl.getBoundingClientRect();
      showOutline(rect);
      placePill(rect);
      return;
    }
    if (mode === 'text') {
      var payload = selectionPayload();
      if (payload) placePill(payload.rect);
      else hidePill();
    }
  }
  document.addEventListener('scroll', reposition, true);
  window.addEventListener('resize', reposition);

  // 供 Flutter 侧主动进入元素点选（工具栏按钮/后续扩展）
  window.__qnoteStartElementPicker = function () {
    ensureUi();
    var el = document.elementFromPoint(
      (window.innerWidth || document.documentElement.clientWidth || 0) / 2,
      (window.innerHeight || document.documentElement.clientHeight || 0) / 2
    );
    if (el) enterElementMode(el);
  };
  window.__qnoteCancelElementPicker = exitElementMode;

  // 网页内选中后如需由 Flutter 侧清理（例如面板关闭），可调用此方法
  window.__qnoteClearSelection = function () {
    exitElementMode();
    clearSelectionUi();
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ensureUi);
  } else {
    ensureUi();
  }
})();
''';
}
