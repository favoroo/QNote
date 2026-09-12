import 'package:flutter/material.dart';

import 'platform_preview.dart' //
    if (dart.library.js_interop) 'platform_preview_web.dart'
    if (dart.library.io) 'platform_preview_mobile.dart';

/// HTML 渲染预览视图。
/// 移动端通过 WebView 加载 HTML 字符串（支持 Tailwind CDN、JS 动效等外链资源），
/// Web 端通过 iframe srcdoc 内嵌渲染，均可真实呈现网页效果而非源码。
class HtmlPreviewView extends StatelessWidget {
  final String htmlContent;

  const HtmlPreviewView({super.key, required this.htmlContent});

  @override
  Widget build(BuildContext context) {
    return PlatformPreview(htmlContent: htmlContent);
  }
}
