import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;
import 'package:webview_flutter/webview_flutter.dart';

import 'html_persistence_helper.dart';

/// Android/iOS 实现：WebView 加载 HTML 字符串，
/// 支持页面内引用的 CDN 脚本、字体、JS 动效以及 LocalStorage 状态持久化
class PlatformPreview extends StatefulWidget {
  final String htmlContent;
  final String? noteId;

  const PlatformPreview({
    super.key,
    required this.htmlContent,
    this.noteId,
  });

  @override
  State<PlatformPreview> createState() => _PlatformPreviewState();
}

class _PlatformPreviewState extends State<PlatformPreview> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // loadHtmlString 的初始导航或沙箱内部导航允许之；
            // 预览内的外链一律交给系统浏览器打开，避免 WebView 内跳走丢失笔记页面
            final url = request.url;
            if (url == 'about:blank' ||
                url.startsWith('data:') ||
                (url.startsWith('https://note-') && url.contains('.qnote.local'))) {
              return NavigationDecision.navigate;
            }
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      );

    _loadContent();
  }

  void _loadContent() {
    final processedHtml = HtmlPersistenceHelper.prepareHtml(widget.htmlContent);
    final baseUrl = HtmlPersistenceHelper.getBaseUrl(widget.noteId);
    _controller.loadHtmlString(processedHtml, baseUrl: baseUrl);
  }

  @override
  void didUpdateWidget(covariant PlatformPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化时重新加载（如悬浮小Q修改笔记后的预览刷新）
    if (widget.htmlContent != oldWidget.htmlContent || widget.noteId != oldWidget.noteId) {
      _loadContent();
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
