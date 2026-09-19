/// 非 io/web 平台的兜底实现（当前目标平台 Web/iOS/Android 均会命中另外两者）。
///
/// 与 `image_saver_io.dart` / `image_saver_web.dart` 保持同一组顶层函数签名，
/// 供 `image_saver.dart` 的条件导入解析。
library;

Future<void> saveImage(String source, String fileName) async {
  throw UnsupportedError('当前平台不支持保存图片');
}

Future<bool> shareImageFallback(String source, String fileName) async {
  return false;
}
