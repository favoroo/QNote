import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

/// Web 端实现：iframe srcdoc 内嵌渲染。
/// webview_flutter 不支持 Web 平台，使用平台视图注册原生 iframe 替代
class PlatformPreview extends StatefulWidget {
  final String htmlContent;

  const PlatformPreview({super.key, required this.htmlContent});

  @override
  State<PlatformPreview> createState() => _PlatformPreviewState();
}

class _PlatformPreviewState extends State<PlatformPreview> {
  late final String _viewType;
  web.HTMLIFrameElement? _iframe;
  late String _currentContent;

  @override
  void initState() {
    super.initState();
    _currentContent = widget.htmlContent;
    // 每个实例注册唯一的平台视图类型，避免同页多实例互相覆盖
    _viewType = 'qnote-html-preview-${const Uuid().v4()}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = web.HTMLIFrameElement()
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      _iframe = iframe;
      // package:web 的 srcdoc setter 参数为 JSAny，字符串需显式转换
      iframe.srcdoc = _currentContent.toJS;
      return iframe;
    });
  }

  @override
  void didUpdateWidget(covariant PlatformPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化时直接更新 srcdoc（如悬浮小Q修改笔记后的预览刷新）
    if (widget.htmlContent != oldWidget.htmlContent) {
      _currentContent = widget.htmlContent;
      _iframe?.srcdoc = _currentContent.toJS;
    }
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
