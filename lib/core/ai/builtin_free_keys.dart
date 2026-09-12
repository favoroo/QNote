import 'dart:math';

import 'package:dio/dio.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/free_model_config.dart';

/// 内置加密免费模型密钥库
///
/// 密钥在代码与编译产物中均以掩码字节数组保存，杜绝明文字符串，
/// 在运行时动态还原，为应用提供开箱即用（离线/导出 APK 即可使用）的免费模型支持。
class BuiltinFreeKeys {
  BuiltinFreeKeys._();

  // 掩码混淆保存的 SenseNova API Keys（无任何明文字符串）
  static const List<int> _k0 = [
    44, 158, 93, 227, 202, 13, 154, 158, 53, 30, 170, 99, 24, 200, 15, 112,
    238, 16, 195, 86, 137, 34, 240, 176, 4, 158, 79, 148, 242, 76, 180, 214,
    139, 27, 185
  ];
  static const List<int> _k1 = [
    44, 158, 93, 156, 228, 51, 164, 199, 102, 61, 145, 73, 57, 229, 65, 88,
    223, 95, 203, 16, 187, 69, 174, 192, 36, 201, 92, 138, 204, 79, 159, 237,
    177, 103, 232
  ];
  static const List<int> _k2 = [
    44, 158, 93, 160, 220, 112, 216, 239, 86, 42, 153, 120, 46, 227, 78, 103,
    195, 109, 210, 23, 186, 38, 168, 147, 56, 136, 76, 132, 201, 8, 149, 236,
    137, 50, 227
  ];
  static const List<int> _k3 = [
    44, 158, 93, 143, 132, 117, 155, 246, 81, 124, 143, 99, 62, 197, 98, 78,
    152, 108, 145, 63, 180, 113, 235, 164, 56, 136, 64, 175, 215, 10, 172, 253,
    143, 38, 135
  ];

  // 掩码混淆保存的 Gemini 网关 API Key（无任何明文字符串）
  static const List<int> _kGemini = [
    44, 158, 93, 189, 194, 114, 220, 145, 63, 116, 233, 62, 123, 155, 7, 47
  ];

  static const List<List<int>> _allEncoded = [_k0, _k1, _k2, _k3];

  /// 掩码向量
  static const List<int> _mask = [0x7A, 0xC5, 0x4B, 0x93, 0xE2, 0x1F, 0x88, 0xD4];

  /// 动态还原单个 API Key
  static String _decode(List<int> bytes) {
    final plain = <int>[];
    for (int i = 0; i < bytes.length; i++) {
      plain.add(bytes[i] ^ _mask[i % _mask.length] ^ ((i * 11 + 37) & 0xFF));
    }
    return String.fromCharCodes(plain);
  }

  /// 获取所有解密后的 SenseNova API Key 列表
  static List<String> getDecryptedKeys() {
    return _allEncoded.map(_decode).toList();
  }

  /// 获取解密后的 Gemini 专用 API Key
  static String getGeminiApiKey() {
    return _decode(_kGemini);
  }

  /// 创建内置的默认 SenseNova 6.8 模型配置
  static FreeModelConfig createDefaultConfig([String? apiKey]) {
    final effectiveKey = apiKey ?? FreeModelKeyManager.instance.acquireNextKey();
    return FreeModelConfig(
      id: 'sensenova-flash-lite',
      displayName: 'SenseNova 6.8',
      provider: 'openai',
      baseUrl: 'https://token.sensenova.cn/v1',
      modelName: 'sensenova-6.8-flash-lite',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 2,
    );
  }

  /// 创建内置的 GLM-5.2 模型配置（共享网关与 4 个内置 Key 轮询）
  static FreeModelConfig createGlmConfig([String? apiKey]) {
    final effectiveKey = apiKey ?? FreeModelKeyManager.instance.acquireNextKey();
    return FreeModelConfig(
      id: 'glm-5.2',
      displayName: 'GLM 5.2',
      provider: 'openai',
      baseUrl: 'https://token.sensenova.cn/v1',
      modelName: 'glm-5.2',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 3,
    );
  }

  /// 创建内置的 DeepSeek-V4-Flash 模型配置（共享网关与 4 个内置 Key 轮询）
  static FreeModelConfig createDeepSeekConfig([String? apiKey]) {
    final effectiveKey = apiKey ?? FreeModelKeyManager.instance.acquireNextKey();
    return FreeModelConfig(
      id: 'deepseek-v4-flash',
      displayName: 'DeepSeek V4 Flash',
      provider: 'openai',
      baseUrl: 'https://token.sensenova.cn/v1',
      modelName: 'deepseek-v4-flash',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 4,
    );
  }

  /// 创建内置的 Gemini 3.8 Flash Low 模型配置
  static FreeModelConfig createGemini38Config([String? apiKey]) {
    final effectiveKey = apiKey ?? getGeminiApiKey();
    return FreeModelConfig(
      id: 'gemini-3.8-flash-low',
      displayName: 'Gemini 3.8 Flash Low',
      provider: 'openai',
      baseUrl: 'https://1demacbook-pro.tail77f123.ts.net/v1',
      modelName: 'gemini-3.8-flash-low',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 1,
    );
  }

  /// 创建内置的 Gemini 3.5 Flash Lite 模型配置（默认推荐）
  static FreeModelConfig createGemini35Config([String? apiKey]) {
    final effectiveKey = apiKey ?? getGeminiApiKey();
    return FreeModelConfig(
      id: 'gemini-3.5-flash-lite',
      displayName: 'Gemini 3.5 Flash Lite',
      provider: 'openai',
      baseUrl: 'https://1demacbook-pro.tail77f123.ts.net/v1',
      modelName: 'gemini-3.5-flash-lite',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 0,
    );
  }
}

/// 免费模型 API Key 轮询与故障转移管理器
///
/// 1. 轮批使用（Round-Robin）：维护全局递增游标，打散日常请求，降低触发限速概率；
/// 2. 限速与故障转移（Failover）：识别 429 限速与鉴权错误，遇到限速自动切换下一个备用 Key 并重试。
class FreeModelKeyManager {
  static final FreeModelKeyManager _instance = FreeModelKeyManager._internal();
  static FreeModelKeyManager get instance => _instance;
  FreeModelKeyManager._internal();

  /// 维护全部可用 Key 池
  List<String> _keys = BuiltinFreeKeys.getDecryptedKeys();

  /// 轮询游标
  int _cursor = 0;

  /// Key 冷却记录（记录被标记限速的时间戳）
  final Map<String, DateTime> _rateLimitedKeys = {};

  /// 冷却时间（1分钟后自动解除冷却状态，避免瞬时限速导致 Key 长期锁定）
  static const Duration _cooldownDuration = Duration(minutes: 1);

  /// 更新 Key 池（支持与外部远程清单扩展融合）
  void updateKeys(List<String> newKeys) {
    if (newKeys.isEmpty) return;
    final merged = <String>{...newKeys, ...BuiltinFreeKeys.getDecryptedKeys()}.toList();
    _keys = merged;
  }

  /// 当前 Key 池总容量
  int get totalKeysCount => _keys.length;

  /// 轮询获取下一个 API Key
  String acquireNextKey() {
    if (_keys.isEmpty) {
      _keys = BuiltinFreeKeys.getDecryptedKeys();
    }
    _cleanExpiredCooldowns();

    // 优先选择未处于冷却状态的 Key
    for (int i = 0; i < _keys.length; i++) {
      final key = _keys[(_cursor + i) % _keys.length];
      if (!_rateLimitedKeys.containsKey(key)) {
        _cursor = (_cursor + i + 1) % _keys.length;
        return key;
      }
    }

    // 若全部均处于冷却，则直接顺位返回，避免不可用
    final key = _keys[_cursor % _keys.length];
    _cursor = (_cursor + 1) % _keys.length;
    return key;
  }

  /// 标记某个 Key 发生限速或故障，并返回下一个备用 Key
  String rotateKeyOnFailure(String failedKey) {
    _rateLimitedKeys[failedKey] = DateTime.now();
    LoggerService.instance.logAI(
      '免费 Key 发生限速或调用失败，自动加入冷却并轮换下一个 Key',
      level: LogLevel.warning,
      details: '受限 Key: ${_maskKey(failedKey)}, 当前受限总数: ${_rateLimitedKeys.length}/${_keys.length}',
    );

    // 1. 优先寻找下一个未处于冷却状态且不等于 failedKey 的 Key
    for (int i = 0; i < _keys.length; i++) {
      final key = _keys[(_cursor + i) % _keys.length];
      if (key != failedKey && !_rateLimitedKeys.containsKey(key)) {
        _cursor = (_cursor + i + 1) % _keys.length;
        return key;
      }
    }

    // 2. 次选：即使全在冷却中，也强制轮询到与 failedKey 不同的下一个 Key
    for (int i = 0; i < _keys.length; i++) {
      final key = _keys[(_cursor + i) % _keys.length];
      if (key != failedKey) {
        _cursor = (_cursor + i + 1) % _keys.length;
        return key;
      }
    }

    // 3. 兜底：若池中只有 1 个 Key 或未匹配到，强制将游标顺位递增取下一个
    final currentIndex = _keys.indexOf(failedKey);
    if (_keys.length > 1 && currentIndex != -1) {
      final nextIndex = (currentIndex + 1) % _keys.length;
      _cursor = (nextIndex + 1) % _keys.length;
      return _keys[nextIndex];
    }

    return failedKey;
  }

  /// 清理已过期的限速冷却记录
  void _cleanExpiredCooldowns() {
    final now = DateTime.now();
    _rateLimitedKeys.removeWhere((_, time) => now.difference(time) > _cooldownDuration);
  }

  /// 计算指数退避延迟时间（含随机抖动 Jitter），避免并发重试瞬时撞墙
  Duration getBackoffDelay(int retryCount) {
    // 基础延时：第 1 次 300ms，第 2 次 600ms，第 3 次 1200ms...
    final baseMs = 300 * (1 << (retryCount - 1).clamp(0, 4));
    // 附加 0~150ms 随机抖动
    final jitter = Random().nextInt(150);
    return Duration(milliseconds: baseMs + jitter);
  }

  /// 判定是否属于可故障转移并重试的错误
  ///
  /// 涵盖：
  /// - 状态码：429（限速）、400（商汤常见并发超限/40003/1102）、401（鉴权失效）、403（禁用）、
  ///          408（请求超时）、500（偶发服务故障）、502/503/504（网关超时与拥塞）
  /// - 网络抖动：超时（connect/send/receive）、TLS 握手中断、连接重置、连接中止、网络断开等
  /// - 文本关键词：并发、超限、配额、rate limit、qps、quota、handshake 等
  bool isRecoverableError(dynamic error) {
    if (error == null) return false;
    if (error is DioException) {
      // 1. 网络连接与超时类错误（网络轻微抖动、网关未响应，均可安全切 Key 重试）
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        return true;
      }

      // 1.1 Dio 未映射的底层异常一律被包成 unknown，TLS 握手中断
      //     （HandshakeException: Connection terminated during handshake）、
      //     连接被重置（SocketException）都落在这个桶里，必须按瞬时网络故障重试。
      //     这里用 runtimeType 名称判断而非 `is`：dart:io 的异常类型无法在 Web 上编译期引用。
      //     唯一排除的是响应体解析失败（FormatException）—— 那是数据问题，重试无意义。
      if (error.type == DioExceptionType.unknown) {
        final inner = error.error;
        if (inner != null && inner is! FormatException) {
          final innerType = inner.runtimeType.toString();
          if (innerType.contains('HandshakeException') ||
              innerType.contains('TlsException') ||
              innerType.contains('SocketException') ||
              innerType.contains('HttpException') ||
              innerType.contains('ClientException') ||
              innerType.contains('TimeoutException')) {
            return true;
          }
        }
      }

      // 2. HTTP 状态码判定
      final statusCode = error.response?.statusCode;
      if (statusCode == 429 ||
          statusCode == 400 ||
          statusCode == 401 ||
          statusCode == 403 ||
          statusCode == 408 ||
          statusCode == 500 ||
          statusCode == 502 ||
          statusCode == 503 ||
          statusCode == 504) {
        return true;
      }

      // 3. 检查状态文本与错误描述
      final statusMessage = error.response?.statusMessage?.toLowerCase() ?? '';
      if (_hasRetryableKeywords(statusMessage)) {
        return true;
      }

      final errorMsg = error.message?.toLowerCase() ?? '';
      if (_hasRetryableKeywords(errorMsg)) {
        return true;
      }

      // 4. 处理非流式 response.data
      final respData = error.response?.data;
      if (respData != null && respData is! ResponseBody) {
        final respStr = respData.toString().toLowerCase();
        if (_hasRetryableKeywords(respStr)) {
          return true;
        }
      }
    }

    final errorStr = error.toString().toLowerCase();
    if (_hasRetryableKeywords(errorStr)) {
      return true;
    }

    return false;
  }

  /// 检查文本是否包含限频、配额、并发超限或服务端网络异常等关键词
  bool _hasRetryableKeywords(String text) {
    if (text.isEmpty) return false;
    return text.contains('429') ||
        text.contains('401') ||
        text.contains('403') ||
        text.contains('400') ||
        text.contains('502') ||
        text.contains('503') ||
        text.contains('rate limit') ||
        text.contains('rate_limit') ||
        text.contains('ratelimit') ||
        text.contains('qps') ||
        text.contains('tpm') ||
        text.contains('rpm') ||
        text.contains('concurrency') ||
        text.contains('quota') ||
        text.contains('insufficient') ||
        text.contains('forbidden') ||
        text.contains('blocked') ||
        text.contains('timeout') ||
        text.contains('timed out') ||
        text.contains('connection refused') ||
        text.contains('connection closed') ||
        text.contains('connection reset') ||
        // TLS 握手阶段被掐断：网关抖动、中间设备重置、网络切换时高频出现，退避重连即可恢复
        text.contains('handshake') ||
        text.contains('connection terminated') ||
        text.contains('connection abort') ||
        text.contains('tls') ||
        text.contains('socket') ||
        text.contains('network') ||
        text.contains('配额') ||
        text.contains('超限') ||
        text.contains('并发') ||
        text.contains('频率') ||
        text.contains('限制') ||
        text.contains('超时') ||
        text.contains('握手') ||
        text.contains('网络') ||
        text.contains('繁忙');
  }

  /// 密钥脱敏显示（用于日志）
  String _maskKey(String key) {
    if (key.length <= 8) return '***';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }
}
