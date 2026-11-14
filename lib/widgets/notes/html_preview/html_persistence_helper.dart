/// HTML 交互状态持久化辅助器。
///
/// 针对小Q编写的网页（包含静态待办表单或自定义页面），通过在渲染前注入轻量
/// 自动持久化脚本，确保在移动端与 Web 端的预览中，表单输入、复选框勾选等交互
/// 能够自动在本地沙箱保存并在退出重开后无缝恢复；同时留存页面滚动位置
/// （含 window 与内部滚动容器），下次打开自动回到上次浏览的位置。
class HtmlPersistenceHelper {
  HtmlPersistenceHelper._();

  /// 通用表单与勾选元素自动留存脚本。
  ///
  /// 逻辑：
  /// 1. 监听全局 input / change 事件，记录 input/textarea/select 的状态至 localStorage；
  /// 2. DOMContentLoaded 或就绪时自动回填已存状态；
  /// 3. 支持 data-no-persist 跳过指定元素；
  /// 4. 监听 reset 事件清理对应表单字段存储；
  /// 5. 捕获阶段监听 scroll（scroll 不冒泡，捕获可同时收到 window 与内部容器的滚动），
  ///    节流保存滚动位置并在页面就绪后带重试恢复，用户主动交互立即终止恢复。
  ///
  /// 脚本内的 `__QNOTE_STORAGE_NS__` 占位符在注入时按平台替换：
  /// 移动端已有 baseUrl 子域隔离，替换为空字符串（键名不变，兼容旧留存数据）；
  /// Web 端 iframe srcdoc 与父页面同源、各笔记共用 localStorage，替换为按笔记
  /// 隔离的命名空间，避免 A 笔记恢复到 B 笔记的状态。
  static const String autoPersistScript = '''
<script id="__qnote_auto_persist_script">
(function() {
  if (window.__qnoteAutoPersistInitialized) return;
  window.__qnoteAutoPersistInitialized = true;

  var STORAGE_NS = '__QNOTE_STORAGE_NS__';
  var STORAGE_PREFIX = '__qnote_form_v1__' + STORAGE_NS;
  var SCROLL_PREFIX = '__qnote_scroll_v1__' + STORAGE_NS;

  function getElementKey(el) {
    if (!el) return null;
    if (el.hasAttribute('data-no-persist') || el.closest('[data-no-auto-persist]')) return null;
    if (el.id) return 'id:' + el.id;
    if (el.name) {
      if (el.type === 'radio') return 'radio:' + el.name + ':' + el.value;
      return 'name:' + el.name;
    }
    var path = [];
    var curr = el;
    while (curr && curr !== document.body && curr !== document.documentElement) {
      var parent = curr.parentNode;
      if (!parent) break;
      var siblings = parent.children;
      var index = 0;
      for (var i = 0; i < siblings.length; i++) {
        if (siblings[i] === curr) { index = i; break; }
      }
      path.unshift((curr.tagName || 'el').toLowerCase() + '[' + index + ']');
      curr = parent;
    }
    return 'path:' + path.join('>');
  }

  function saveValue(el) {
    var key = getElementKey(el);
    if (!key) return;
    try {
      if (el.type === 'checkbox') {
        localStorage.setItem(STORAGE_PREFIX + key, el.checked ? '1' : '0');
      } else if (el.type === 'radio') {
        if (el.checked) {
          localStorage.setItem(STORAGE_PREFIX + 'radiogroup:' + el.name, el.value);
        }
      } else if (el.tagName === 'SELECT') {
        localStorage.setItem(STORAGE_PREFIX + key, el.value);
      } else if (typeof el.value !== 'undefined') {
        localStorage.setItem(STORAGE_PREFIX + key, el.value);
      }
    } catch (e) {}
  }

  function restoreAll() {
    try {
      var inputs = document.querySelectorAll('input, textarea, select');
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        var key = getElementKey(el);
        if (!key) continue;

        if (el.type === 'checkbox') {
          var val = localStorage.getItem(STORAGE_PREFIX + key);
          if (val !== null) el.checked = (val === '1');
        } else if (el.type === 'radio') {
          var checkedVal = localStorage.getItem(STORAGE_PREFIX + 'radiogroup:' + el.name);
          if (checkedVal !== null) el.checked = (el.value === checkedVal);
        } else if (el.tagName === 'SELECT' || typeof el.value !== 'undefined') {
          var saved = localStorage.getItem(STORAGE_PREFIX + key);
          if (saved !== null) el.value = saved;
        }
      }
    } catch (e) {}
  }

  function attachListeners() {
    document.addEventListener('input', function(e) {
      if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) {
        saveValue(e.target);
      }
    }, true);

    document.addEventListener('change', function(e) {
      if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT')) {
        saveValue(e.target);
      }
    }, true);

    document.addEventListener('reset', function(e) {
      setTimeout(function() {
        if (!e.target) return;
        var elements = e.target.querySelectorAll ? e.target.querySelectorAll('input, textarea, select') : [];
        for (var i = 0; i < elements.length; i++) {
          var k = getElementKey(elements[i]);
          if (k) {
            try { localStorage.removeItem(STORAGE_PREFIX + k); } catch (err) {}
          }
        }
      }, 50);
    }, true);
  }

  // ===== 滚动位置留存 =====

  var scrollPending = {};
  var flushTimer = null;
  var restoreAborted = false;
  var restoreTries = 0;
  var restoreTarget = null;
  var savedScrollKeys = null;
  var lastRestoreAt = 0;

  function isScrollPersistDisabled() {
    try {
      var root = document.documentElement;
      var body = document.body;
      return (root && root.hasAttribute('data-no-scroll-persist')) ||
          (body && body.hasAttribute('data-no-scroll-persist'));
    } catch (e) { return false; }
  }

  function getScrollKey(t) {
    if (t === window || t === document || t === document.documentElement) return 'window';
    if (!t || t.nodeType !== 1 || !t.hasAttribute) return null;
    if (t.hasAttribute('data-no-scroll-persist')) return null;
    return getElementKey(t);
  }

  function flushScrolls() {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = null; }
    try {
      for (var k in scrollPending) {
        if (!Object.prototype.hasOwnProperty.call(scrollPending, k)) continue;
        var p = scrollPending[k];
        localStorage.setItem(SCROLL_PREFIX + k, p.x + ',' + p.y);
      }
      scrollPending = {};
    } catch (e) {}
  }

  function queueScrollSave(t) {
    if (isScrollPersistDisabled()) return;
    var key = getScrollKey(t);
    if (!key) return;
    var x, y;
    if (key === 'window') {
      x = window.pageXOffset || document.documentElement.scrollLeft || 0;
      y = window.pageYOffset || document.documentElement.scrollTop || 0;
    } else {
      x = t.scrollLeft || 0;
      y = t.scrollTop || 0;
    }
    scrollPending[key] = { x: x, y: y };
    if (!flushTimer) flushTimer = setTimeout(flushScrolls, 250);
  }

  function loadSavedScrolls() {
    try {
      var out = {};
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (k && k.indexOf(SCROLL_PREFIX) === 0) {
          out[k.substring(SCROLL_PREFIX.length)] = localStorage.getItem(k);
        }
      }
      return out;
    } catch (e) { return {}; }
  }

  function parsePair(raw) {
    if (!raw) return null;
    var parts = String(raw).split(',');
    var x = parseFloat(parts[0]);
    var y = parseFloat(parts[1]);
    if (isNaN(x) || isNaN(y)) return null;
    return { x: x, y: y };
  }

  function findScrollableContainers() {
    var out = [];
    try {
      var els = document.querySelectorAll('*');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        if (el.hasAttribute && el.hasAttribute('data-no-scroll-persist')) continue;
        var cs;
        try { cs = window.getComputedStyle(el); } catch (err) { continue; }
        var canY = (cs.overflowY === 'auto' || cs.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 1;
        var canX = (cs.overflowX === 'auto' || cs.overflowX === 'scroll') && el.scrollWidth > el.clientWidth + 1;
        if (canY || canX) out.push(el);
      }
    } catch (e) {}
    return out;
  }

  function windowTargetReached() {
    if (!restoreTarget) return true;
    var doc = document.documentElement;
    var max = Math.max(0, doc.scrollHeight - window.innerHeight);
    var goal = Math.min(restoreTarget.y, max);
    var cur = window.pageYOffset || doc.scrollTop || 0;
    return Math.abs(cur - goal) < 2;
  }

  function applyScrollRestore() {
    lastRestoreAt = Date.now();
    try {
      if (restoreTarget) window.scrollTo(restoreTarget.x, restoreTarget.y);
      if (savedScrollKeys) {
        var needScan = false;
        for (var k in savedScrollKeys) {
          if (k !== 'window') { needScan = true; break; }
        }
        if (needScan) {
          var els = findScrollableContainers();
          for (var i = 0; i < els.length; i++) {
            var key = getElementKey(els[i]);
            if (!key || !savedScrollKeys[key]) continue;
            var p = parsePair(savedScrollKeys[key]);
            if (!p) continue;
            els[i].scrollTop = p.y;
            els[i].scrollLeft = p.x;
          }
        }
      }
    } catch (e) {}
  }

  function restoreLoop() {
    if (restoreAborted || restoreTries >= 12) return;
    restoreTries++;
    applyScrollRestore();
    if (restoreAborted) return;
    var hasContainerKeys = false;
    for (var k in savedScrollKeys) {
      if (k !== 'window') { hasContainerKeys = true; break; }
    }
    if (windowTargetReached() && !hasContainerKeys) return;
    setTimeout(restoreLoop, 150);
  }

  function startScrollRestore() {
    if (isScrollPersistDisabled()) return;
    savedScrollKeys = loadSavedScrolls();
    var hasAny = false;
    for (var k in savedScrollKeys) { hasAny = true; break; }
    if (!hasAny) { savedScrollKeys = null; return; }
    restoreTarget = parsePair(savedScrollKeys['window']);
    restoreLoop();
  }

  function attachScrollListeners() {
    // 捕获阶段监听：scroll 事件不冒泡，只有捕获才能同时收到 window 与内部容器的滚动
    document.addEventListener('scroll', function(e) {
      if (Date.now() - lastRestoreAt < 100) return; // 恢复脚本自身触发的滚动，不算用户行为
      restoreAborted = true; // 用户开始主动滚动，终止未完成的恢复重试
      queueScrollSave(e.target);
    }, true);

    // 用户交互立即终止恢复，避免重试把人拉回旧位置
    var abortEvents = ['touchstart', 'pointerdown', 'mousedown', 'wheel', 'keydown'];
    for (var i = 0; i < abortEvents.length; i++) {
      document.addEventListener(abortEvents[i], function() { restoreAborted = true; }, true);
    }

    // WebView / iframe 可能未经 unload 直接销毁，隐藏或离开时立即落盘兜底
    document.addEventListener('visibilitychange', function() {
      if (document.visibilityState === 'hidden') flushScrolls();
    });
    window.addEventListener('pagehide', flushScrolls);
    window.addEventListener('beforeunload', flushScrolls);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      restoreAll();
      attachListeners();
      startScrollRestore();
      attachScrollListeners();
    });
  } else {
    restoreAll();
    attachListeners();
    startScrollRestore();
    attachScrollListeners();
  }
})();
</script>
''';

  /// 为特定笔记生成完全隔离的同源 baseUrl。
  ///
  /// 利用浏览器的 Origin 规范（RFC 6454，Origin 由协议+域名+端口决定），
  /// 通过子域名隔离（如 `https://note-123.qnote.local/`），确保每篇 HTML 笔记
  /// 拥有专属的 localStorage 与沙箱命名空间，避免不同网页间的状态相互冲突。
  static String getBaseUrl(String? noteId) {
    final cleanId = (noteId ?? 'local')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final idSegment = cleanId.isEmpty ? 'local' : cleanId;
    return 'https://note-$idSegment.qnote.local/';
  }

  /// 清洗存储命名空间：仅保留小写字母、数字与连字符，非空时追加 `__` 分隔，
  /// 确保不同笔记的键名互不前缀重叠。
  static String _sanitizeStorageNamespace(String? namespace) {
    if (namespace == null || namespace.isEmpty) return '';
    final clean = namespace
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return clean.isEmpty ? '' : '${clean}__';
  }

  /// 在 HTML 适当位置注入自动状态留存器脚本。
  ///
  /// [storageNamespace] 仅在共享 origin 的环境下需要传入（如 Web 端 iframe
  /// srcdoc 与父页面同源），用于按笔记隔离 localStorage 键名；移动端依赖
  /// baseUrl 子域隔离，不传即可保持旧键名与既有留存数据兼容。
  static String prepareHtml(String htmlContent, {String? storageNamespace}) {
    if (htmlContent.contains('__qnote_auto_persist_script')) {
      return htmlContent;
    }
    final ns = _sanitizeStorageNamespace(storageNamespace);
    final script = autoPersistScript.replaceAll("STORAGE_NS = '__QNOTE_STORAGE_NS__'", "STORAGE_NS = '$ns'");
    if (htmlContent.contains('</body>')) {
      return htmlContent.replaceFirst('</body>', '$script\n</body>');
    }
    if (htmlContent.contains('</head>')) {
      return htmlContent.replaceFirst('</head>', '$script\n</head>');
    }
    return '$htmlContent\n$script';
  }
}
