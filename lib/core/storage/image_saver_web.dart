import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web 端图片保存实现：用隐藏 `<a download>` 触发浏览器下载。
///
/// Web 端生图结果是 `data:` URI（无对应磁盘文件），可直接作为 href；
/// `http(s)` / `blob:` 来源先转成同源 object URL，绕过 `download` 属性对跨域资源无效的限制。
Future<void> saveImage(String source, String fileName) async {
  final trimmed = source.trim();
  final href = trimmed.startsWith('data:')
      ? trimmed
      : await _toObjectUrl(trimmed);
  final anchor = web.HTMLAnchorElement()
    ..href = href
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

/// 保存失败时 Web 端没有系统分享面板可降级，返回 false 由上层提示错误。
Future<bool> shareImageFallback(String source, String fileName) async {
  return false;
}

Future<String> _toObjectUrl(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  if (!response.ok) {
    throw Exception('拉取图片失败：HTTP ${response.status}');
  }
  final blob = await response.blob().toDart;
  return web.URL.createObjectURL(blob);
}
