import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:qnote_flutter/core/ai/sensenova_quota_policy.dart';
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
  static const List<int> _k4 = [
    44, 158, 93, 165, 225, 38, 157, 244, 63, 24, 174, 97, 46, 238, 117, 113,
    194, 80, 215, 35, 140, 73, 237, 155, 31, 144, 74, 146, 240, 76, 133, 235,
    136, 96, 230
  ];
  static const List<int> _k5 = [
    44, 158, 93, 167, 193, 1, 140, 206, 112, 57, 225, 63, 2, 157, 126, 78,
    198, 29, 207, 80, 176, 92, 211, 151, 1, 147, 101, 137, 236, 42, 189, 234,
    173, 38, 231
  ];
  static const List<int> _k6 = [
    44, 158, 93, 133, 212, 59, 167, 196, 72, 0, 171, 74, 121, 223, 85, 103,
    150, 79, 250, 4, 132, 102, 197, 164, 101, 186, 75, 183, 233, 77, 223, 155,
    180, 35, 185
  ];
  static const List<int> _k7 = [
    44, 158, 93, 187, 213, 55, 136, 148, 102, 47, 162, 88, 49, 248, 91, 113,
    157, 16, 213, 38, 144, 67, 173, 183, 0, 153, 77, 142, 223, 46, 134, 221,
    187, 34, 138
  ];
  static const List<int> _k8 = [
    44, 158, 93, 143, 217, 2, 140, 206, 105, 124, 168, 91, 60, 201, 99, 91,
    253, 105, 148, 17, 166, 65, 238, 197, 52, 138, 107, 170, 241, 23, 178, 154,
    205, 32, 152
  ];

  // 掩码混淆保存的 CPA 网关 API Key（无任何明文字符串；历史名字沿用 Gemini，
  // 因为该密钥最初就是为 Gemini 通道签发。内置模型全部转投商汤网关后暂无消费者，
  // 保留给 CPA 隧道端点相关能力与后续回插模型使用）
  static const List<int> _kGemini = [
    44, 158, 93, 189, 194, 114, 220, 145, 63, 116, 233, 62, 123, 155, 7, 47
  ];

  static const List<List<int>> _allEncoded = [
    _k0, _k1, _k2, _k3, _k4, _k5, _k6, _k7, _k8
  ];

  /// 默认兜底的 Tailscale 永久公网地址
  static const String defaultTailscaleBaseUrl = 'https://1demacbook-pro.tail77f123.ts.net/v1';

  /// 当前生效的 CPA BaseURL (支持远程动态拉取 Cloudflare 极速地址)
  static String dynamicCpaBaseUrl = defaultTailscaleBaseUrl;

  /// 当前生效的 CPA 备用 BaseURL（云端 fallback_base_url 字段）
  ///
  /// primary 端点持续握手失败时可切换的备用地址；为空表示云端未提供有效备用地址
  static String dynamicCpaFallbackBaseUrl = '';

  /// 更新当前生效的 CPA BaseURL
  static void updateDynamicCpaBaseUrl(String newUrl) {
    if (newUrl.trim().isNotEmpty) {
      dynamicCpaBaseUrl = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
      if (!dynamicCpaBaseUrl.endsWith('/v1')) {
        dynamicCpaBaseUrl = '$dynamicCpaBaseUrl/v1';
      }
    }
  }

  /// 更新 CPA 备用 BaseURL；传空串表示清除（如云端 fallback 与 primary 相同时不单列）
  static void updateDynamicCpaFallbackBaseUrl(String? newUrl) {
    final trimmed = (newUrl ?? '').trim();
    if (trimmed.isEmpty) {
      dynamicCpaFallbackBaseUrl = '';
      return;
    }
    var normalized = trimmed.replaceAll(RegExp(r'/+$'), '');
    if (!normalized.endsWith('/v1')) {
      normalized = '$normalized/v1';
    }
    dynamicCpaFallbackBaseUrl = normalized;
  }

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

  /// 获取解密后的 CPA 网关专用 API Key（方法名沿用历史 Gemini 称呼）
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

  /// 创建内置的 DeepSeek Flash 模型配置（共享网关与 4 个内置 Key 轮询，默认推荐）
  static FreeModelConfig createDeepSeekConfig([String? apiKey]) {
    final effectiveKey = apiKey ?? FreeModelKeyManager.instance.acquireNextKey();
    return FreeModelConfig(
      id: 'deepseek-flash',
      displayName: 'DeepSeek Flash',
      provider: 'openai',
      baseUrl: 'https://token.sensenova.cn/v1',
      modelName: 'deepseek-flash',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 0,
    );
  }

  /// 创建内置的 SenseNova U1.5 Lite 生图模型配置（商汤日日新文生图，无水印公测）
  static FreeModelConfig createSenseNovaU15ImageConfig([String? apiKey]) {
    final effectiveKey = apiKey ?? FreeModelKeyManager.instance.acquireNextKey();
    return FreeModelConfig(
      id: 'sensenova-u1.5-lite',
      displayName: 'SenseNova 生图',
      provider: 'openai',
      baseUrl: 'https://token.sensenova.cn/v1',
      modelName: 'sensenova-u1.5-lite',
      obfuscatedApiKey: effectiveKey,
      authType: 'bearer',
      priority: 1,
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

  /// Key 冷却记录 —— value 存的是**解锁时刻**而不是标记时刻
  ///
  /// 限流分两层且代价差两个数量级（rps 突发 2 秒即可复用、TPM 额度要等一分钟回填），
  /// 所以冷却时长必须由调用方按形态传入；存终点还让 [earliestCooldownEndAt] 能直接
  /// 回答「整池最早什么时候能用」，供上层排队而不是直接报错。
  final Map<String, DateTime> _cooldownUntil = {};

  /// 默认冷却时长（1 分钟）—— 对齐商汤 TPM 按分钟滚动的回填窗口
  static const Duration _cooldownDuration = Duration(minutes: 1);

  /// 全池最近一次「真正发出请求」的时刻，用于 [nextSendWait] 的跨消费者节流
  ///
  /// 主聊天 / 悬浮小Q / 日记提取 / 每日评分 / 生图共用这一个进程内单例，
  /// 没有这道闸会在同一次事件循环里把请求叠出去撞网关的 `rps exhausted`。
  DateTime? _lastSendAt;

  /// 更新 Key 池（支持与外部远程清单扩展融合）
  void updateKeys(List<String> newKeys) {
    if (newKeys.isEmpty) return;
    final merged = <String>{...newKeys, ...BuiltinFreeKeys.getDecryptedKeys()}.toList();
    _keys = merged;
  }

  /// 当前 Key 池总容量
  int get totalKeysCount => _keys.length;

  /// 单模型内最多轮换几把 Key（护栏，不再是单次请求的重试深度）
  ///
  /// 2026-09-25 实测推翻了这个常量的原始依据：原本认为「各把 Key 配额独立，逐把扫完
  /// 整池也就 1~2 秒」，实际是 9 把 Key 在 1 秒内各发一次 → 0/9 全 TPM 拒绝、两把 Key
  /// 在同一秒恢复，额度更像整池共享、按分钟回填。所以单次请求的深度改由
  /// `SensenovaQuotaPolicy.poolMaxAttempts`（4 把）决定；这里保留池容量口径，
  /// 供诊断日志与 [FreeModelExecutor] 的换 Key 预算使用。
  static const int maxKeyRotationAttempts = 12;

  /// 池容量口径的轮换预算（不超过 [maxKeyRotationAttempts]）
  int get keyRotationAttempts =>
      totalKeysCount < maxKeyRotationAttempts ? totalKeysCount : maxKeyRotationAttempts;

  /// 当前还有没有未被置入冷却的 Key
  ///
  /// 调用方（`AiService._shouldRetryAndWait`）用它判断「现在换 Key 还有没有意义」：
  /// 一把都不剩时不再连发，而是按 [earliestCooldownEndAt] 排队等回填 —— 实测额度
  /// 按分钟滚动恢复，换 Key 与换模型都躲不开同一个 429。
  bool hasAvailableKey() {
    if (_keys.isEmpty) return false;
    _cleanExpiredCooldowns();
    return _keys.any((k) => !_cooldownUntil.containsKey(k));
  }

  /// 未被冷却的 Key 数量（诊断与日志用）
  int get availableKeyCount {
    if (_keys.isEmpty) return 0;
    _cleanExpiredCooldowns();
    return _keys.where((k) => !_cooldownUntil.containsKey(k)).length;
  }

  /// 轮询获取下一个 API Key
  String acquireNextKey() {
    if (_keys.isEmpty) {
      _keys = BuiltinFreeKeys.getDecryptedKeys();
    }
    _cleanExpiredCooldowns();

    // 优先选择未处于冷却状态的 Key
    for (int i = 0; i < _keys.length; i++) {
      final key = _keys[(_cursor + i) % _keys.length];
      if (!_cooldownUntil.containsKey(key)) {
        _cursor = (_cursor + i + 1) % _keys.length;
        return key;
      }
    }

    // 若全部均处于冷却，则直接顺位返回，避免不可用
    final key = _keys[_cursor % _keys.length];
    _cursor = (_cursor + 1) % _keys.length;
    return key;
  }

  /// 把某把 Key 按指定时长置入冷却
  ///
  /// [cooldown] 为 [Duration.zero] 时什么都不做 —— 网关 5xx、TLS 抖动、业务参数错误都不该
  /// 记到 Key 头上（历史行为是「任何可恢复错误都关它一分钟」，结果池子被自己的非配额故障
  /// 掏空，而配额本身是按分钟回填的，锁着也没用）。
  void markKeyLimited(String key, {required Duration cooldown}) {
    if (key.isEmpty || cooldown <= Duration.zero) return;
    _cooldownUntil[key] = DateTime.now().add(cooldown);
  }

  /// 某把 Key 距离解锁还有多久（不在冷却中返回 [Duration.zero]）
  Duration cooldownRemaining(String key) {
    _cleanExpiredCooldowns();
    final endAt = _cooldownUntil[key];
    if (endAt == null) return Duration.zero;
    final remaining = endAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 整池中**最早**解锁的时刻；一把都没在冷却时返回 null
  ///
  /// 这是「排队等回填」而不是「整池冷却就报错」的数据来源：额度按分钟滚动恢复，
  /// 等到这个时刻再发，比换 Key 重复撞同一批 429 有用得多。
  DateTime? earliestCooldownEndAt() {
    _cleanExpiredCooldowns();
    if (_cooldownUntil.isEmpty) return null;
    return _cooldownUntil.values.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// 距离「全池允许再发一次请求」还需等待多久（[Duration.zero] 表示可立即发）
  ///
  /// 与 [acquireNextKey] 分开成两个方法，是为了让取 Key 保持**无副作用的纯游标推进**
  /// （既有单测依赖它的顺序语义），节流只在发信侧这一层生效。
  Duration nextSendWait() {
    final last = _lastSendAt;
    if (last == null) return Duration.zero;
    final wait = SensenovaQuotaPolicy.minSendInterval - DateTime.now().difference(last);
    return wait.isNegative ? Duration.zero : wait;
  }

  /// 记录一次真正发出去的请求，作为 [nextSendWait] 的节流锚点
  void noteRequestSent() {
    _lastSendAt = DateTime.now();
  }

  /// 标记某个 Key 发生限速或故障，并返回下一个备用 Key
  ///
  /// [cooldown] 由调用方按限流形态给出（见 `SensenovaQuotaPolicy.keyCooldown`）；
  /// 不传时沿用默认的 1 分钟，保持历史调用点语义不变。
  String rotateKeyOnFailure(String failedKey, {Duration? cooldown}) {
    final effectiveCooldown = cooldown ?? _cooldownDuration;
    markKeyLimited(failedKey, cooldown: effectiveCooldown);
    LoggerService.instance.logAI(
      '免费 Key 发生限速或调用失败，已置入冷却并轮换下一个 Key',
      level: LogLevel.warning,
      details: '受限 Key: ${maskKey(failedKey)}, 冷却 ${effectiveCooldown.inSeconds}s, '
          '当前受限总数: ${_cooldownUntil.length}/${_keys.length}',
    );

    // 1. 优先寻找下一个未处于冷却状态且不等于 failedKey 的 Key
    for (int i = 0; i < _keys.length; i++) {
      final key = _keys[(_cursor + i) % _keys.length];
      if (key != failedKey && !_cooldownUntil.containsKey(key)) {
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

  /// 清理已到期的冷却记录（解锁时刻已过即视为可用）
  void _cleanExpiredCooldowns() {
    final now = DateTime.now();
    _cooldownUntil.removeWhere((_, endAt) => !endAt.isAfter(now));
  }

  /// 计算指数退避延迟时间（含随机抖动 Jitter），避免并发重试瞬时撞墙
  Duration getBackoffDelay(int retryCount) {
    // 基础延时：第 1 次 300ms，第 2 次 600ms，第 3 次 1200ms...
    final baseMs = 300 * (1 << (retryCount - 1).clamp(0, 4));
    // 附加 0~150ms 随机抖动
    final jitter = Random().nextInt(150);
    return Duration(milliseconds: baseMs + jitter);
  }

  /// 连接层瞬时故障的专用退避（含随机抖动 Jitter）
  ///
  /// TLS 握手中断 / 连接重置这类故障常来自网关隧道重连或证书冷启动（如 Tailscale
  /// Funnel 握手耗时可达数秒），300ms 级的通用退避在恢复完成前就烧完全部次数，
  /// 因此放宽为 1s/2s/4s/8s，给隧道重建留出穿越窗口。
  Duration getConnectionBackoffDelay(int retryCount) {
    // 基础延时：第 1 次 1s，第 2 次 2s，第 3 次 4s，第 4 次及以后 8s
    final baseMs = 1000 * (1 << (retryCount - 1).clamp(0, 3));
    final jitter = Random().nextInt(150);
    return Duration(milliseconds: baseMs + jitter);
  }

  /// 判定是否属于连接层瞬时故障（TLS 握手中断、DNS 后的 TCP/TLS 建连失败）
  ///
  /// 与 [isRecoverableError] 的区别：仅覆盖「重新建连/等待网关恢复」才有意义的
  /// 错误，用于启用更长的重试窗口与动态端点刷新；HTTP 状态码、限流配额等
  /// 服务端语义错误不在此列（它们重试再久也不会好，走原有通用策略即可）。
  bool isConnectionClassError(dynamic error) {
    if (error is! DioException) return false;
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError) {
      return true;
    }
    // Dio 未映射的底层异常被包成 unknown，用 runtimeType 名称判断
    // （dart:io 异常类型无法在 Web 上编译期引用，与 isRecoverableError 同理）
    if (error.type == DioExceptionType.unknown) {
      final inner = error.error;
      if (inner == null || inner is FormatException) return false;
      final innerType = inner.runtimeType.toString();
      return innerType.contains('HandshakeException') ||
          innerType.contains('TlsException') ||
          innerType.contains('SocketException');
    }
    return false;
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
        // 网关的秒级突发保护（`rps exhausted`）与配额耗尽同样是瞬时故障
        text.contains('rps') ||
        text.contains('exhausted') ||
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

  /// 判定该错误是否「Key 自身配额」造成 —— 换一把 Key 值得立刻再试
  ///
  /// 与 [isRecoverableError] 的关系是本函数的严格子集：只覆盖 429/401/403 与
  /// 限流、配额、并发超限类文案。5xx 与 TLS/连接抖动不在此列 —— 那是端点侧问题，
  /// 换 Key 无意义，仍应走指数退避。
  ///
  /// 注：本方法只回答「是不是配额问题」。**该不该等、等多久**改由
  /// `SensenovaQuotaPolicy.classify` + `rotationDelay` 决定 —— 因为实测网关有两层
  /// 限流（TPM 额度与 `rps exhausted` 秒级突发），而额度更像整池共享、按分钟回填，
  /// 「换到 Key 就能零等待」的旧结论已经不成立。
  bool isKeyScopedError(dynamic error) {
    if (error == null) return false;

    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode == 429 || statusCode == 401 || statusCode == 403) {
        return true;
      }
      if (_hasQuotaKeywords(error.response?.statusMessage?.toLowerCase() ?? '')) {
        return true;
      }
      if (_hasQuotaKeywords(error.message?.toLowerCase() ?? '')) {
        return true;
      }
      final respData = error.response?.data;
      if (respData != null && respData is! ResponseBody) {
        if (_hasQuotaKeywords(respData.toString().toLowerCase())) {
          return true;
        }
      }
    }

    return _hasQuotaKeywords(error.toString().toLowerCase());
  }

  /// 限流/配额/并发超限/Key 失效类关键词（[isKeyScopedError] 的文案判据）
  ///
  /// 数字只保留 429：401/403 由上面的状态码分支精确命中，把它们当子串匹配
  /// 会被「token 数里带 401」这类无关文本误伤。
  bool _hasQuotaKeywords(String text) {
    if (text.isEmpty) return false;
    return text.contains('429') ||
        text.contains('rate limit') ||
        text.contains('rate_limit') ||
        text.contains('ratelimit') ||
        // 商汤两层限流的原话：`RateLimitExceeded.EndpointTPMExceeded` 与 `rps exhausted`
        // （历史上没有 rps 字样，导致带内 SSE 错误既不算可恢复也不算配额，一次都不重试）
        text.contains('ratelimitexceeded') ||
        text.contains('rps') ||
        text.contains('exhausted') ||
        text.contains('too many requests') ||
        text.contains('tpm') ||
        text.contains('rpm') ||
        text.contains('qps') ||
        text.contains('quota') ||
        text.contains('concurrency') ||
        text.contains('insufficient') ||
        text.contains('forbidden') ||
        text.contains('配额') ||
        text.contains('超限') ||
        text.contains('并发') ||
        text.contains('频率') ||
        text.contains('繁忙');
  }

  /// 重置轮询游标与全部冷却记录（仅测试用）
  ///
  /// 冷却表是进程内单例状态，既有用例靠「本条必须排在最后」维持顺序，非常脆；
  /// 有了这个方法测试可以在 setUp 里自行清场。
  @visibleForTesting
  void resetForTest() {
    _cooldownUntil.clear();
    _lastSendAt = null;
    _cursor = 0;
  }

  /// 密钥脱敏显示（用于日志），保证明文 Key 不落盘、不进日志文件
  static String maskKey(String key) {
    if (key.length <= 8) return '***';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }
}
