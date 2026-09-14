/// HTML 交互状态持久化辅助器。
///
/// 针对小Q编写的网页（包含静态待办表单或自定义页面），通过在渲染前注入轻量
/// 自动持久化脚本，确保在移动端与 Web 端的预览中，表单输入、复选框勾选等交互
/// 能够自动在本地沙箱保存并在退出重开后无缝恢复。
class HtmlPersistenceHelper {
  HtmlPersistenceHelper._();

  /// 通用表单与勾选元素自动留存脚本。
  ///
  /// 逻辑：
  /// 1. 监听全局 input / change 事件，记录 input/textarea/select 的状态至 localStorage；
  /// 2. DOMContentLoaded 或就绪时自动回填已存状态；
  /// 3. 支持 data-no-persist 跳过指定元素；
  /// 4. 监听 reset 事件清理对应表单字段存储。
  static const String autoPersistScript = '''
<script id="__qnote_auto_persist_script">
(function() {
  if (window.__qnoteAutoPersistInitialized) return;
  window.__qnoteAutoPersistInitialized = true;

  var STORAGE_PREFIX = '__qnote_form_v1__';

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

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      restoreAll();
      attachListeners();
    });
  } else {
    restoreAll();
    attachListeners();
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

  /// 在 HTML 适当位置注入自动状态留存器脚本。
  static String prepareHtml(String htmlContent) {
    if (htmlContent.contains('__qnote_auto_persist_script')) {
      return htmlContent;
    }
    if (htmlContent.contains('</body>')) {
      return htmlContent.replaceFirst('</body>', '$autoPersistScript\n</body>');
    }
    if (htmlContent.contains('</head>')) {
      return htmlContent.replaceFirst('</head>', '$autoPersistScript\n</head>');
    }
    return '$htmlContent\n$autoPersistScript';
  }
}
