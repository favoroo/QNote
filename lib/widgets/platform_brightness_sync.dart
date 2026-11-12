import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 让 iOS 原生控件（键盘、系统菜单、日期/相机选择器等）的明暗跟随 App 背景。
///
/// App 的明暗由「背景预设」决定，可以完全独立于手机的系统深色开关。但 iOS 上的
/// 键盘、文本选择菜单、相册/相机面板这些系统 UI 只认 `overrideUserInterfaceStyle`，
/// 默认仍跟随系统：用户在浅色 App 里点开输入框，会弹出一块深色键盘，观感割裂。
///
/// 这里在明暗变化时通知原生侧对齐。走自定义通道是因为 Flutter 没有跨平台 API
/// 暴露该属性。
class PlatformBrightnessSync extends StatefulWidget {
  const PlatformBrightnessSync({super.key, required this.child});

  final Widget child;

  static const MethodChannel _channel = MethodChannel('com.appone.qnote_flutter/appearance');

  @override
  State<PlatformBrightnessSync> createState() => _PlatformBrightnessSyncState();
}

class _PlatformBrightnessSyncState extends State<PlatformBrightnessSync> {
  Brightness? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 只在 iOS 上处理：Android 的键盘明暗由系统主题接管，桌面与 Web 没有这个概念。
    // 用 defaultTargetPlatform 而不是 dart:io Platform，后者在 Web 构建下不可用。
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    final brightness = Theme.of(context).brightness;
    if (brightness == _applied) {
      return;
    }
    _applied = brightness;
    // fire-and-forget：原生侧尚未注册该通道时静默忽略，
    // 不能因为一次外观同步失败影响界面
    PlatformBrightnessSync._channel
        .invokeMethod<void>('setUserInterfaceStyle', brightness == Brightness.dark ? 'dark' : 'light')
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
