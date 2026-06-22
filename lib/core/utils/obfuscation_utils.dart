import 'dart:convert';

/// 简单混淆工具
///
/// 用于对免费模型的 apikey 进行简单混淆，避免明文存储在 GitHub 公开仓库。
/// 注意：此方案非加密，反编译可获取密钥，仅提高门槛。
class ObfuscationUtils {
  // 混淆密钥（硬编码，反编译可见，仅提高门槛）
  static const String _key = 'qnote_2026_free_models_obfuscation_key';

  /// 混淆：XOR → Base64编码 → 字符串翻转
  static String obfuscate(String plainText) {
    // 1. XOR
    final xorBytes = <int>[];
    for (int i = 0; i < plainText.length; i++) {
      xorBytes.add(plainText.codeUnitAt(i) ^ _key.codeUnitAt(i % _key.length));
    }
    // 2. Base64编码
    final base64Str = base64Encode(xorBytes);
    // 3. 字符串翻转
    return String.fromCharCodes(base64Str.codeUnits.reversed);
  }

  /// 解混淆：字符串翻转 → Base64解码 → XOR
  static String deobfuscate(String obfuscatedText) {
    try {
      // 1. 字符串翻转
      final base64Str =
          String.fromCharCodes(obfuscatedText.codeUnits.reversed);
      // 2. Base64解码
      final xorBytes = base64Decode(base64Str);
      // 3. XOR
      final plainCodes = <int>[];
      for (int i = 0; i < xorBytes.length; i++) {
        plainCodes.add(xorBytes[i] ^ _key.codeUnitAt(i % _key.length));
      }
      return String.fromCharCodes(plainCodes);
    } catch (e) {
      // 解混淆失败返回空字符串，避免崩溃
      return '';
    }
  }
}
