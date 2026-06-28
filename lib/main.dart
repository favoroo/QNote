import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// P2-35: 启动优化——先 runApp 渲染首帧（splash），初始化在 QNoteApp 内部后台并行完成。
///
/// 原实现串行 await 8 个初始化步骤（Logger/日期/数据库工厂/数据库/4 个配置/WebDAV/通知），
/// 用户看到黑屏直到全部完成。现改为 runApp 立即显示 splash，初始化完成后切换到主应用。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: QNoteApp()));
}
