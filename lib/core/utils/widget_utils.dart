import 'package:flutter/services.dart';

/// 桌面小组件工具类，用于 Flutter 侧与原生小组件进行数据通信与状态刷新
class WidgetUtils {
  static const _channel = MethodChannel('com.appone.qnote_flutter/widgets');

  /// 通知原生小组件（今日待办、快捷记录）刷新数据
  static Future<void> updateHomeWidgets() async {
    try {
      await _channel.invokeMethod('updateWidgets');
    } on PlatformException catch (_) {
      // 捕获异常，防止非 Android 平台或通道未准备就绪时崩溃
      // 实际开发中也可以在原生端捕获未实现的方法
    }
  }
}
