import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/utils/html_selection_quote.dart';

import 'platform_preview.dart' //
    if (dart.library.js_interop) 'platform_preview_web.dart'
    if (dart.library.io) 'platform_preview_mobile.dart';

/// HTML 渲染预览视图。
/// 移动端通过 WebView 加载 HTML 字符串（支持 Tailwind CDN、JS 动效等外链资源），
/// Web 端通过 iframe srcdoc 内嵌渲染，均可真实呈现网页效果而非源码。
///
/// [onSelection] 非空时启用网页内选择探针：用户在网页里选中文字或长按元素，
/// 网页内会浮出「给小Q」按钮，点击后把 DOM 信息（选择器/outerHTML/位置）回传。
class HtmlPreviewView extends StatelessWidget {
  final String htmlContent;
  final String? noteId;
  final ValueChanged<HtmlSelectionPayload>? onSelection;

  const HtmlPreviewView({super.key, required this.htmlContent, this.noteId, this.onSelection});

  @override
  Widget build(BuildContext context) {
    return PlatformPreview(
      htmlContent: htmlContent,
      noteId: noteId,
      onSelectionMessage: onSelection == null ? null : _handleSelectionMessage,
    );
  }

  void _handleSelectionMessage(String raw) {
    final payload = HtmlSelectionPayload.tryParse(raw);
    if (payload != null) {
      onSelection!(payload);
    }
  }
}
