import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import 'html_persistence_helper.dart';
import 'html_selection_bridge.dart';

/// Web 端实现：iframe srcdoc 内嵌渲染。
/// webview_flutter 不支持 Web 平台，使用平台视图注册原生 iframe 替代，
/// 注入 HtmlPersistenceHelper 脚本以支持交互状态自动恢复与 LocalStorage 留存；
/// 同时注入选择探针，iframe 内选中的文字/元素经 postMessage 回传给父页面。
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
  late final String _viewType;

  /// 探针会话 token：父页面据此过滤其他 iframe / 页面发来的无关消息
  final String _selectionToken = const Uuid().v4().replaceAll('-', '');

  late final JSFunction _messageListener;
  web.HTMLIFrameElement? _iframe;
  late String _currentContent;

  @override
  void initState() {
    super.initState();
    _currentContent = _prepare(widget.htmlContent);
    // 每个实例注册唯一的平台视图类型，避免同页多实例互相覆盖
    _viewType = 'qnote-html-preview-${const Uuid().v4()}';

    _messageListener = ((web.Event event) {
      final message = event as web.MessageEvent;
      final data = message.data?.dartify();
      if (data is! String) return;
      // token 为 32 位十六进制随机串，出现在 payload 中即可认定来自本预览
      if (!data.contains(_selectionToken)) return;
      widget.onSelectionMessage?.call(data);
    }).toJS;
    web.window.addEventListener('message', _messageListener);

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

  String _prepare(String html) {
    // srcdoc iframe 与父页面同源，所有笔记共用 localStorage，须按笔记隔离留存键名
    final withPersistence = HtmlPersistenceHelper.prepareHtml(html, storageNamespace: widget.noteId);
    return HtmlSelectionBridge.prepareHtml(withPersistence, token: _selectionToken);
  }

  @override
  void didUpdateWidget(covariant PlatformPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化时直接更新 srcdoc（如悬浮小Q修改笔记后的预览刷新）
    if (widget.htmlContent != oldWidget.htmlContent || widget.noteId != oldWidget.noteId) {
      _currentContent = _prepare(widget.htmlContent);
      _iframe?.srcdoc = _currentContent.toJS;
    }
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _messageListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
