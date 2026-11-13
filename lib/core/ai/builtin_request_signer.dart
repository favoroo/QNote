import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/ai/builtin_service_secret.dart';

/// 内置服务请求头：安装 ID 用于网关设备配额，签名用于挡掉随手扫描。
///
/// 始终发送安装 ID（即使没注入 app secret），这样内测阶段关闭签名校验时，
/// 配额仍然按设备而不是按一整个 IP 统计。
class BuiltinRequestSigner {
  BuiltinRequestSigner._();

  static const String _installKey = 'builtin_install_id';
  static String? _cachedInstallId;

  /// 安装期 UUID：首次生成后写入 SharedPreferences；「清空所有数据」会重建
  static Future<String> installId() async {
    final cached = _cachedInstallId;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_installKey);
      if (id == null || id.trim().isEmpty) {
        id = const Uuid().v4();
        await prefs.setString(_installKey, id);
      }
      _cachedInstallId = id;
      return id;
    } catch (_) {
      // 极端情况下读不到 SharedPreferences 也不能让请求发不出去：退化为进程内 ID
      final fallback = const Uuid().v4();
      _cachedInstallId = fallback;
      return fallback;
    }
  }

  /// 生成内置服务请求头；未注入 app secret 时只带安装 ID
  static Future<Map<String, String>> headersForPath(String path) async {
    final id = await BuiltinRequestSigner.installId();
    final headers = <String, String>{'X-QNote-Install': id, 'X-QNote-Client': 'qnote/${_clientVersion()}'};
    final secret = builtinAppSecret.trim();
    if (secret.isEmpty) return headers;
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = '$id\n$timestamp\n${normalizePath(path)}';
    headers['X-QNote-Timestamp'] = '$timestamp';
    headers['X-QNote-Sign'] = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(payload)).toString();
    return headers;
  }

  /// 网关按 `url.pathname` 计算签名：这里统一成「以 / 开头、不含 query」的形式
  static String normalizePath(String path) {
    var value = path.trim();
    if (value.isEmpty) return '/';
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) {
      value = uri.path.isEmpty ? '/' : uri.path;
    }
    final queryIndex = value.indexOf('?');
    if (queryIndex >= 0) value = value.substring(0, queryIndex);
    if (!value.startsWith('/')) value = '/$value';
    return value;
  }

  static String _clientVersion() {
    try {
      return AppVersion.version;
    } catch (_) {
      // 测试或极早期调用时 AppVersion 可能还没初始化
      return 'unknown';
    }
  }
}
