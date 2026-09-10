import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';

/// 应用安装服务，处理不同平台下的安装包安装与跳转。
class AppInstaller {
  AppInstaller._();

  static const MethodChannel _installerChannel = MethodChannel('com.appone.qnote_flutter/installer');

  /// 尝试安装本地 APK（仅 Android 支持）。
  ///
  /// 通过原生 MethodChannel 调起系统应用安装器。
  static Future<bool> installApk(String filePath) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      final result = await _installerChannel.invokeMethod<bool>(
        'installApk',
        <String, dynamic>{'filePath': filePath},
      );
      return result ?? false;
    } on PlatformException catch (e, stackTrace) {
      LoggerService.instance.error(
        '调起 APK 安装失败: ${e.message}',
        category: LogCategory.system,
        details: stackTrace.toString(),
      );
      return false;
    } catch (e, stackTrace) {
      LoggerService.instance.error(
        '调起 APK 安装异常: $e',
        category: LogCategory.system,
        details: stackTrace.toString(),
      );
      return false;
    }
  }

  /// 降级跳转：使用系统外部浏览器打开指定下载或 Release 页面。
  static Future<bool> openInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      return false;
    }
  }
}
