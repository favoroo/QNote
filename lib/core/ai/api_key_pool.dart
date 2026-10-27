import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// 厂商条目 API Key 池的轮询与冷却状态
///
/// 语义对齐 CLIProxyAPI 的 provider + api-keys：同一厂商条目下的多把 Key 按
/// round-robin 逐请求轮换；某把 Key 撞上 429/鉴权/配额类错误时进入冷却，
/// 轮换自动跳过它，冷却到期自动回池。Key 列表本身来自厂商条目（数据库），
/// 本类只持有**进程内的轮换状态**（游标 + 冷却表），不含任何持久化数据。
class ApiKeyPool {
  ApiKeyPool._();

  static final ApiKeyPool instance = ApiKeyPool._();

  /// 单次请求触发换 Key 重试的深度上限（池再大也不会把一次提问耗光）
  static const int maxRotationAttempts = 4;

  /// Key 撞墙后的默认冷却时长（额度通常按分钟滚动回填）
  static const Duration defaultCooldown = Duration(minutes: 1);

  /// 冷却时长上限：尊重端点返回的 Retry-After，但不允许把一把 Key 关到天荒地老
  static const Duration maxCooldown = Duration(minutes: 10);

  /// 整池都在冷却时，排队等最早解锁的最长等待
  static const Duration maxPoolWait = Duration(seconds: 30);

  /// providerId → 轮询游标
  final Map<String, int> _cursor = {};

  /// providerId → (key → 解锁时刻)
  final Map<String, Map<String, DateTime>> _cooldownUntil = {};

  /// 让池状态与厂商条目的当前 Key 列表对齐
  ///
  /// 用户在设置里增删密钥后，游标与冷却表里可能残留已删除的 Key：
  /// 这里按传入列表收敛，避免残留项无限累积。
  void syncKeys(String providerId, List<String> keys) {
    final keySet = keys.toSet();
    final cursor = _cursor[providerId];
    if (cursor != null && keys.isNotEmpty && cursor >= keys.length * 2) {
      _cursor[providerId] = cursor % keys.length;
    }
    final cooldowns = _cooldownUntil[providerId];
    if (cooldowns != null) {
      cooldowns.removeWhere((key, until) =>
          !keySet.contains(key) || !until.isAfter(DateTime.now()));
      if (cooldowns.isEmpty) _cooldownUntil.remove(providerId);
    }
  }

  /// 取下一把可用 Key（round-robin，跳过冷却中的；全在冷却时返回最早解锁的一把）
  String? acquireNext(String providerId, List<String> keys) {
    if (keys.isEmpty) return null;
    if (keys.length == 1) return keys.first;

    syncKeys(providerId, keys);
    final cursor = _cursor[providerId] ?? 0;
    final cooldowns = _cooldownUntil[providerId];
    for (var i = 0; i < keys.length; i++) {
      final index = (cursor + i) % keys.length;
      final key = keys[index];
      if (cooldowns == null || !cooldowns.containsKey(key)) {
        _cursor[providerId] = (index + 1) % keys.length;
        return key;
      }
    }
    // 整池冷却：返回最早解锁的一把，由调用方决定是排队等待还是直接报错
    var earliest = keys.first;
    var earliestAt = cooldowns![earliest];
    for (final key in keys) {
      final until = cooldowns[key];
      if (until == null) return key;
      if (earliestAt == null || until.isBefore(earliestAt)) {
        earliest = key;
        earliestAt = until;
      }
    }
    _cursor[providerId] = (keys.indexOf(earliest) + 1) % keys.length;
    return earliest;
  }

  /// 记录一次「这把 Key 撞墙了」，进入冷却
  void markLimited(
    String providerId,
    String key, {
    Duration cooldown = defaultCooldown,
  }) {
    if (key.trim().isEmpty) return;
    final effective = cooldown > maxCooldown ? maxCooldown : cooldown;
    final cooldowns = _cooldownUntil.putIfAbsent(providerId, () => {});
    cooldowns[key] = DateTime.now().add(effective);
  }

  /// 从 429/503 响应的 Retry-After 头解析冷却时长（解析不到用默认值）
  Duration cooldownFromError(dynamic error) {
    if (error is DioException) {
      final headers = error.response?.headers;
      final retryAfter = headers?.value('retry-after');
      if (retryAfter != null) {
        final seconds = int.tryParse(retryAfter.trim());
        if (seconds != null && seconds > 0) {
          return Duration(seconds: seconds);
        }
      }
    }
    return defaultCooldown;
  }

  /// 池内是否还有未冷却的 Key（[keys] 为当前厂商的全部有效密钥）
  bool hasAvailable(String providerId, List<String> keys) {
    if (keys.isEmpty) return false;
    final cooldowns = _cooldownUntil[providerId];
    if (cooldowns == null || cooldowns.isEmpty) return true;
    final now = DateTime.now();
    cooldowns.removeWhere((_, until) => !until.isAfter(now));
    return keys.any((k) => !cooldowns.containsKey(k));
  }

  /// 最早解锁时刻；无冷却时返回 null
  DateTime? earliestCooldownEnd(String providerId) {
    final cooldowns = _cooldownUntil[providerId];
    if (cooldowns == null || cooldowns.isEmpty) return null;
    final now = DateTime.now();
    cooldowns.removeWhere((_, until) => !until.isAfter(now));
    DateTime? earliest;
    for (final until in cooldowns.values) {
      if (earliest == null || until.isBefore(earliest)) earliest = until;
    }
    return earliest;
  }

  /// 某把 Key 剩余冷却时长（不在冷却返回 Duration.zero）
  Duration cooldownRemaining(String providerId, String key) {
    final until = _cooldownUntil[providerId]?[key];
    if (until == null) return Duration.zero;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 清空某个厂商的轮换状态（删除厂商 / 修改密钥后调用）
  void reset(String providerId) {
    _cursor.remove(providerId);
    _cooldownUntil.remove(providerId);
  }

  @visibleForTesting
  void resetForTest() {
    _cursor.clear();
    _cooldownUntil.clear();
  }

  // ── 通用错误分类与退避（原内置 Key 管理器的通用部分，与具体网关无关）──

  /// 计算指数退避延迟（含随机抖动），避免并发重试瞬时撞墙
  static Duration getBackoffDelay(int retryCount) {
    // 基础延时：第 1 次 300ms，第 2 次 600ms，第 3 次 1200ms...
    final baseMs = 300 * (1 << (retryCount - 1).clamp(0, 4));
    final jitter = Random().nextInt(150);
    return Duration(milliseconds: baseMs + jitter);
  }

  /// 连接层瞬时故障的专用退避（含随机抖动）
  ///
  /// TLS 握手中断 / 连接重置这类故障常来自网关重连或证书冷启动，300ms 级的
  /// 通用退避在恢复完成前就烧完全部次数，因此放宽为 1s/2s/4s/8s。
  static Duration getConnectionBackoffDelay(int retryCount) {
    final baseMs = 1000 * (1 << (retryCount - 1).clamp(0, 3));
    final jitter = Random().nextInt(150);
    return Duration(milliseconds: baseMs + jitter);
  }

  /// 判定是否属于连接层瞬时故障（TLS 握手中断、TCP/TLS 建连失败）
  static bool isConnectionClassError(dynamic error) {
    if (error is! DioException) return false;
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError) {
      return true;
    }
    // Dio 未映射的底层异常被包成 unknown，用 runtimeType 名称判断
    // （dart:io 异常类型无法在 Web 上编译期引用）
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

  /// 判定是否属于可重试的瞬时故障
  ///
  /// 涵盖状态码 400/401/403/408/429/5xx、超时与连接抖动、以及限流/配额/并发
  /// 类文案。业务性 4xx（如参数非法、模型不存在）不在其中，重试无意义。
  static bool isRecoverableError(dynamic error) {
    if (error == null) return false;
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        return true;
      }

      // Dio 未映射的底层异常一律被包成 unknown，TLS 握手中断、连接被重置
      // 都落在这个桶里，必须按瞬时网络故障重试。用 runtimeType 名称判断而非
      // `is`：dart:io 的异常类型无法在 Web 上编译期引用。
      // 唯一排除的是响应体解析失败（FormatException）—— 那是数据问题。
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

      final statusMessage = error.response?.statusMessage?.toLowerCase() ?? '';
      if (_hasRetryableKeywords(statusMessage)) return true;

      final errorMsg = error.message?.toLowerCase() ?? '';
      if (_hasRetryableKeywords(errorMsg)) return true;

      final respData = error.response?.data;
      if (respData != null && respData is! ResponseBody) {
        if (_hasRetryableKeywords(respData.toString().toLowerCase())) {
          return true;
        }
      }
    }

    return _hasRetryableKeywords(error.toString().toLowerCase());
  }

  /// 判定该错误是否「Key 自身配额/鉴权」造成 —— 换一把 Key 值得立刻再试
  ///
  /// 是 [isRecoverableError] 的严格子集：只覆盖 429/401/403 与限流、配额、
  /// 并发超限类文案。5xx 与 TLS/连接抖动不在此列 —— 那是端点侧问题，换 Key 无意义。
  static bool isKeyScopedError(dynamic error) {
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

  /// 检查文本是否包含限频、配额、并发超限或服务端网络异常等关键词
  static bool _hasRetryableKeywords(String text) {
    if (text.isEmpty) return false;
    return text.contains('429') ||
        text.contains('401') ||
        text.contains('403') ||
        text.contains('400') ||
        text.contains('502') ||
        text.contains('503') ||
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

  /// 限流/配额/并发超限/Key 失效类关键词（[isKeyScopedError] 的文案判据）
  ///
  /// 数字只保留 429：401/403 由状态码分支精确命中，把它们当子串匹配会被
  /// 「token 数里带 401」这类无关文本误伤。
  static bool _hasQuotaKeywords(String text) {
    if (text.isEmpty) return false;
    return text.contains('429') ||
        text.contains('rate limit') ||
        text.contains('rate_limit') ||
        text.contains('ratelimit') ||
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

  /// 密钥脱敏显示（用于日志/界面），保证明文 Key 不落日志
  static String maskKey(String key) {
    final trimmed = key.trim();
    if (trimmed.length <= 8) return '***';
    return '${trimmed.substring(0, 4)}...${trimmed.substring(trimmed.length - 4)}';
  }
}