import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'package:qnote_flutter/core/utils/toast_utils.dart';

import 'image_saver_stub.dart' //
    if (dart.library.js_interop) 'image_saver_web.dart'
    if (dart.library.io) 'image_saver_io.dart';

/// 图片「下载 / 保存到相册」的统一入口。
///
/// 聊天里的图片来源有两种：原生端是本地文件绝对路径，Web 端是 `data:` URI
/// （见 `GenerateImageTool._saveImages`）。两者都用同一个 `saveWithToast` 处理，
/// 平台差异由条件导入的 `image_saver_io` / `image_saver_web` 承担，不引入额外依赖。
class ImageSaver {
  ImageSaver._();

  /// 是否为内联数据图片（Web 端生图落盘形态，无对应磁盘文件）。
  static bool isInlineData(String source) {
    final trimmed = source.trim();
    return trimmed.startsWith('data:') || trimmed.startsWith('blob:');
  }

  /// 推断保存文件名：文件路径沿用原文件名（生图文件名为 uuid，天然唯一），
  /// 内联数据图按 data URI 的媒体类型补扩展名并加时间戳。
  static String suggestFileName(String source) {
    final trimmed = source.trim();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    if (isInlineData(trimmed)) {
      return 'QNote_$stamp.${_extensionOfMime(_mimeOfDataUri(trimmed))}';
    }
    final normalized = trimmed.replaceAll('\\', '/');
    final baseName = normalized.substring(normalized.lastIndexOf('/') + 1);
    if (baseName.contains('.')) {
      return baseName;
    }
    return 'QNote_$stamp.png';
  }

  /// 保存图片到系统相册（Web 端为浏览器下载），失败抛出异常由调用方处理。
  static Future<void> saveToGallery(String source, {String? fileName}) {
    return saveImage(source, fileName ?? suggestFileName(source));
  }

  /// UI 层直接调用：保存 + Toast 反馈；原生端保存失败时降级为系统分享面板。
  static Future<void> saveWithToast(
    BuildContext context,
    String source, {
    String? fileName,
  }) async {
    if (source.trim().isEmpty) {
      Toast.warning(context, '图片数据为空，无法保存');
      return;
    }
    final name = fileName ?? suggestFileName(source);
    try {
      await saveImage(source, name);
      if (!context.mounted) {
        return;
      }
      Toast.success(context, kIsWeb ? '已开始下载 $name' : '已保存到相册');
    } catch (error) {
      // 权限被拒或存储异常时，分享面板里的「存储到照片 / 文件」仍可完成同样的目的
      var recovered = false;
      try {
        recovered = await shareImageFallback(source, name);
      } catch (_) {
        recovered = false;
      }
      if (!context.mounted) {
        return;
      }
      if (recovered) {
        Toast.info(context, '直接保存失败，已打开分享面板');
      } else {
        Toast.error(context, '保存失败：$error');
      }
    }
  }

  /// 从 data URI 前缀里取媒体类型，如 `data:image/png;base64,...` → `image/png`。
  static String _mimeOfDataUri(String source) {
    final commaIndex = source.indexOf(',');
    final meta = commaIndex == -1 ? source : source.substring(0, commaIndex);
    final colonIndex = meta.indexOf(':');
    final semicolonIndex = meta.indexOf(';');
    if (colonIndex == -1) {
      return 'image/png';
    }
    return semicolonIndex == -1
        ? meta.substring(colonIndex + 1)
        : meta.substring(colonIndex + 1, semicolonIndex);
  }

  static String _extensionOfMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      default:
        return 'png';
    }
  }
}
