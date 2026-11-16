import 'package:flutter/services.dart' show rootBundle;

/// Mermaid 运行库加载：读取本地内置的 `assets/js/mermaid.min.js` 并缓存。
///
/// 体积约 2.5MB；预览每次重建（编辑源码都会重建）都要用同一份源码，
/// 因此读一次后缓存字符串，避免反复读盘。
class MermaidAssets {
  MermaidAssets._();

  /// 运行库资源路径（在 pubspec.yaml 的 `assets/js/` 目录声明下）
  static const String assetPath = 'assets/js/mermaid.min.js';

  static String? _cached;
  static bool _failed = false;

  /// 返回运行库源码；资源缺失或读取失败返回 null（调用方降级为源码展示）
  static Future<String?> load() async {
    if (_cached != null) return _cached;
    if (_failed) return null;
    try {
      _cached = await rootBundle.loadString(assetPath);
      return _cached;
    } catch (_) {
      // 资源缺失只影响 Mermaid 预览，降级为源码展示即可，不打断用户
      _failed = true;
      return null;
    }
  }
}
