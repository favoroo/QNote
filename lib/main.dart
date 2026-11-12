import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// 应用启动入口
///
/// 初始化流程分两阶段：
/// 1. 关键路径（本函数内 await）：Logger、日期格式化、数据库、核心配置——必须在 runApp 前完成，
///    确保首帧渲染时数据库就绪，避免日记页面出现 loading 圈或白屏。
/// 2. 延迟初始化（QNoteApp.initState 内）：WebDAV 同步检查、通知提醒启动——首帧后后台执行，不阻塞用户。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 状态栏样式不在这里预置：此时还不知道用户选的浅色/深色背景，写死深色图标会在深色
  // 主题下出现亮图标压深色底的错配。首帧起由 QNoteApp 的 AnnotatedRegion 按实际主题接管。
  await preInitializeApp();
  runApp(const ProviderScope(child: QNoteApp()));
}
