import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl, LaunchMode;
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'html_persistence_helper.dart';
import 'html_selection_bridge.dart';

/// Android/iOS 实现：WebView 加载 HTML 字符串，
/// 支持页面内引用的 CDN 脚本、字体、JS 动效以及 LocalStorage 状态持久化；
/// 同时注入选择探针，把网页内选中的文字/元素通过 JS Channel 回传给 Flutter。
class PlatformPreview extends StatefulWidget {
  final String htmlContent;
  final String? noteId;

  /// 网页内「给小Q」被点击时回传原始 JSON（由上层解析并组装引用）
  final ValueChanged<String>? onSelectionMessage;

  const PlatformPreview({super.key, required this.htmlContent, this.noteId, this.onSelectionMessage});

  @override
  State<PlatformPreview> createState() => _PlatformPreviewState();
}

class _PlatformPreviewState extends State<PlatformPreview> {
  late final WebViewController _controller;

  /// 探针会话 token：同一预览实例的多次加载保持一致，便于排查与过滤
  final String _selectionToken = const Uuid().v4().replaceAll('-', '');

  /// JS Channel 注册完成前不加载页面，避免探针先于通道就绪导致消息丢失
  bool _channelReady = false;

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

    _initController();
  }

  Future<void> _initController() async {
    try {
      await _controller.addJavaScriptChannel(
        'QNoteHtmlSelection',
        onMessageReceived: (message) {
          widget.onSelectionMessage?.call(message.message);
        },
      );
    } catch (_) {
      // 通道注册失败只影响「选中发给小Q」，不能因此不渲染网页本身
    }
    if (!mounted) {
      return;
    }
    _channelReady = true;
    _loadContent();
  }

  void _loadContent() {
    final processedHtml = HtmlPersistenceHelper.prepareHtml(widget.htmlContent);
    final htmlWithSelection = HtmlSelectionBridge.prepareHtml(processedHtml, token: _selectionToken);
    final baseUrl = HtmlPersistenceHelper.getBaseUrl(widget.noteId);
    _controller.loadHtmlString(htmlWithSelection, baseUrl: baseUrl);
  }

  @override
  void didUpdateWidget(covariant PlatformPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化时重新加载（如悬浮小Q修改笔记后的预览刷新）；
    // 通道还没就绪时无需处理，_initController 会用最新内容首次加载
    if (!_channelReady) {
      return;
    }
    if (widget.htmlContent != oldWidget.htmlContent || widget.noteId != oldWidget.noteId) {
      _loadContent();
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
