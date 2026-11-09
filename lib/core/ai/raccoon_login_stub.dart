import 'raccoon_login_types.dart';

/// Web 等没有 `dart:io` 的平台：只能用「粘贴回调链接/Token」兜底
Future<RaccoonLoopbackLogin> startRaccoonLoopbackLogin({
  Duration timeout = const Duration(minutes: 10),
  Future<void> Function(String code)? onCode,
}) async {
  throw UnsupportedError('当前平台不支持浏览器回环登录，请使用「粘贴回调链接/Token」方式');
}
