import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// 小米运动健康（hlth.io.mi.com）云端通信加解密工具类
/// 协议规格：RC4-drop1024 + SHA256 派生 SignedNonce + 双重 SHA-1 签名
class MiFitnessCrypto {
  /// RC4 加密/解密算法实现，并在 PRGA 前置丢弃 [drop] 字节的密钥流（小米默认丢弃 1024 字节）
  static Uint8List rc4Drop1024(Uint8List key, Uint8List data, {int drop = 1024}) {
    final s = Uint8List(256);
    for (int i = 0; i < 256; i++) {
      s[i] = i;
    }

    int j = 0;
    for (int i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final temp = s[i];
      s[i] = s[j];
      s[j] = temp;
    }

    int i = 0;
    j = 0;
    // 丢弃前 drop 字节密钥流
    for (int k = 0; k < drop; k++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final temp = s[i];
      s[i] = s[j];
      s[j] = temp;
    }

    // 异或加解密
    final out = Uint8List(data.length);
    for (int k = 0; k < data.length; k++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final temp = s[i];
      s[i] = s[j];
      s[j] = temp;
      out[k] = data[k] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }

  /// 生成 12 字节 Nonce (8 字节安全随机数 + 4 字节大端整数时间戳/分钟)
  static Uint8List generateRawNonce({DateTime? now, Random? randomSource}) {
    final random = randomSource ?? Random.secure();
    final bytes = Uint8List(12);
    for (int i = 0; i < 8; i++) {
      bytes[i] = random.nextInt(256);
    }
    final time = now ?? DateTime.now();
    final minutes = time.millisecondsSinceEpoch ~/ 60000;
    final byteData = ByteData.sublistView(bytes, 8, 12);
    byteData.setUint32(0, minutes, Endian.big);
    return bytes;
  }

  /// 根据 ssecurity (Base64) 与 12 字节 rawNonce 计算 32 字节 signedNonce
  /// 公式：SHA256(Base64Decode(ssecurity) + rawNonce)
  static Uint8List computeSignedNonce(String ssecurityB64, Uint8List rawNonce) {
    final ssecBytes = base64.decode(ssecurityB64);
    final combined = Uint8List(ssecBytes.length + rawNonce.length)
      ..setAll(0, ssecBytes)
      ..setAll(ssecBytes.length, rawNonce);
    final digest = sha256.convert(combined);
    return Uint8List.fromList(digest.bytes);
  }

  /// 构建 SHA-1 签名
  /// 待签字符串规范：METHOD&PATH&key1=val1&key2=val2&...&signedNonceB64 (按 key ASCII 升序)
  static String buildSignature(
    String method,
    String path,
    Map<String, String> params,
    String signedNonceB64,
  ) {
    final sortedKeys = params.keys.toList()..sort();
    final parts = <String>[method.toUpperCase(), path];
    for (final k in sortedKeys) {
      parts.add('$k=${params[k]}');
    }
    parts.add(signedNonceB64);
    final msg = parts.join('&');
    final digest = sha1.convert(utf8.encode(msg));
    return base64.encode(digest.bytes);
  }

  /// 构建客户端换取 serviceToken 时的 clientSign
  /// clientSign = UrlEncode(Base64(SHA1("nonce=" + nonce + "&" + ssecurity)))
  static String buildClientSign(dynamic nonce, String ssecurity) {
    final str = 'nonce=$nonce&$ssecurity';
    final hash = sha1.convert(utf8.encode(str));
    final b64 = base64.encode(hash.bytes);
    return Uri.encodeComponent(b64);
  }

  /// 加密请求参数并生成完整的发送表单字段集合
  static Map<String, String> encryptRequestParams({
    required String method,
    required String path,
    required String ssecurityB64,
    required Map<String, dynamic> payload,
    Uint8List? customRawNonce,
  }) {
    final rawNonce = customRawNonce ?? generateRawNonce();
    final nonceB64 = base64.encode(rawNonce);

    final signedNonceBytes = computeSignedNonce(ssecurityB64, rawNonce);
    final signedNonceB64 = base64.encode(signedNonceBytes);

    // 原始数据紧凑 JSON
    final dataPlain = json.encode(payload);
    final rawParams = {'data': dataPlain};

    // 1. 计算预加密签名 rc4_hash__
    final rc4Hash = buildSignature(method, path, rawParams, signedNonceB64);
    rawParams['rc4_hash__'] = rc4Hash;

    // 2. 对所有参数值执行 RC4-drop1024 加密并 Base64
    final encParams = <String, String>{};
    for (final entry in rawParams.entries) {
      final cipherBytes = rc4Drop1024(
        signedNonceBytes,
        Uint8List.fromList(utf8.encode(entry.value)),
      );
      encParams[entry.key] = base64.encode(cipherBytes);
    }

    // 3. 计算加密后的最终 signature
    final signature = buildSignature(method, path, encParams, signedNonceB64);

    return {
      ...encParams,
      'signature': signature,
      '_nonce': nonceB64,
    };
  }

  /// 解密服务端响应数据
  static dynamic decryptResponse({
    required String ssecurityB64,
    required String nonceB64,
    required String responseBodyText,
  }) {
    final trimmed = responseBodyText.trim();
    if (trimmed.isEmpty) return null;

    final rawNonce = base64.decode(nonceB64);
    final signedNonceBytes = computeSignedNonce(ssecurityB64, rawNonce);
    final cipherBytes = base64.decode(trimmed);

    final plainBytes = rc4Drop1024(signedNonceBytes, cipherBytes);
    final plainText = utf8.decode(plainBytes);
    return json.decode(plainText);
  }
}
