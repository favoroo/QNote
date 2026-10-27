import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/ai_provider_repository.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/daily_score.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/health_sport_record.dart';
import 'package:qnote_flutter/models/screen_usage_info.dart';
import 'package:uuid/uuid.dart';

class NoUsefulInfoException implements Exception {
  final String? message;
  NoUsefulInfoException([this.message]);

  @override
  String toString() =>
      message != null ? 'NoUsefulInfoException: $message' : 'NoUsefulInfoException';
}

/// 带工具流式对话的单个流片段。
///
/// - [text] 非 null：模型正文增量，供打字机渲染
/// - [reasoningText] 非 null：模型思考/推理增量（reasoning_content 等），
///   供「思考中」状态卡实时滚动展示思考过程，减少等待体感
/// - [toolProgress] 非 null：模型正在流式生成某工具调用的参数，
///   携带工具名与已拼接的部分参数快照，供 UI 在长参数生成期间
///   （如 write_file 写大文件）展示「正在写入文件 · 路径」等进行中状态
class AiToolStreamChunk {
  final String? text;
  final String? reasoningText;
  final ToolCallProgress? toolProgress;

  const AiToolStreamChunk.text(this.text)
      : reasoningText = null,
        toolProgress = null;

  const AiToolStreamChunk.reasoning(this.reasoningText)
      : text = null,
        toolProgress = null;

  const AiToolStreamChunk.toolProgress(this.toolProgress)
      : text = null,
        reasoningText = null;
}

/// 工具调用参数的流式生成进度快照
class ToolCallProgress {
  final String toolName;

  /// 截至当前的原始参数 JSON 片段（可能不完整，仅用于展示层提取关键信息）
  final String partialArguments;

  const ToolCallProgress({required this.toolName, required this.partialArguments});
}

class AiService {
  final Dio _dio = Dio(
    BaseOptions(
      // 连接超时收紧到 12s：端点为 Cloudflare Quick Tunnel / Tailscale Funnel，
      // 正常建连在秒级；30s 会让连接类故障在 5 次重试中累积出 ~97 秒的等待
      // （见 2026-09-20 「对话发送失败」事故复盘）。接收超时保持 2 分钟，
      // 大模型流式长响应需要足够窗口。
      connectTimeout: _connectTimeoutForChat,
      receiveTimeout: const Duration(minutes: 2),
      sendTimeout: const Duration(seconds: 30),
    ),
  );
  AiConfig? _config;
  double _temperature = 0.7;
  int _maxTokens = 2048;
  String? _reasoningEffort;

  /// 是否锁定用 [_config] 里的 Key 发请求（不参与内置池逐请求轮换）
  ///
  /// 由 [updateConfig] 每次按入参重置，不传即 false —— 忘记重置会让上一次
  /// 「逐把测连通」的锁定语义泄漏到后续真实对话请求里。
  bool _pinApiKey = false;

  AiConfig? get config => _config;

  /// 更新当前生效的 AI 配置
  ///
  /// [pinApiKey] 为 true 时**锁定**用 [config.apiKey] 发请求，不参与密钥池轮换。
  /// 唯一合法用途是「逐把 Key 测连通性」，否则池轮换会把指定 Key 的测试语义静默吃掉。
  ///
  /// 多 Key 厂商的请求**不使用**这里写入的全局 Authorization header —— Key 在每次
  /// 真正发信时由 [_beginSend] 现取并用逐请求 header 覆写（见 [_authOverride]），
  /// 因此池场景下 [_config] 的 apiKey 只是兜底值（池内首把），排查请求实际用了哪把
  /// Key 要以请求日志里的 `Key=<掩码>` 为准。
  void updateConfig(
    AiConfig config, {
    double? temperature,
    int? maxTokens,
    bool pinApiKey = false,
  }) {
    String cleanedBaseUrl = _cleanUrl(config.baseUrl);

    // If Gemini and baseUrl is empty, default to official Gemini API endpoint
    if (config.provider == 'gemini' && cleanedBaseUrl.isEmpty) {
      cleanedBaseUrl = 'https://generativelanguage.googleapis.com';
    }

    if (config.apiKey.isEmpty || cleanedBaseUrl.isEmpty) {
      throw ArgumentError('AI配置不完整: apiKey或baseUrl为空');
    }

    if (!cleanedBaseUrl.startsWith('http://') &&
        !cleanedBaseUrl.startsWith('https://')) {
      throw ArgumentError('Base URL格式错误: 必须以http://或https://开头');
    }

    final Uri? uri = Uri.tryParse(cleanedBaseUrl);
    if (uri == null || uri.host.isEmpty) {
      throw ArgumentError('Base URL格式无效: $cleanedBaseUrl');
    }

    _config = config;
    _pinApiKey = pinApiKey;
    if (temperature != null) _temperature = temperature;
    if (maxTokens != null) _maxTokens = maxTokens;
    _dio.options.baseUrl = cleanedBaseUrl.endsWith('/')
        ? cleanedBaseUrl
        : '$cleanedBaseUrl/';

    // 从提供商配置读取默认推理强度
    _reasoningEffort = _resolveReasoningEffort(config);

    _dio.options.headers['Content-Type'] = 'application/json';
    if (config.provider == 'gemini') {
      _dio.options.headers['x-goog-api-key'] = config.apiKey;
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer ${config.apiKey}';
      _dio.options.headers.remove('x-goog-api-key');
    }

    LoggerService.instance.logAI(
      '更新AI配置: 厂商=${config.vendorId ?? 'custom'}, 提供商=${config.provider}, 模型=${config.modelName}',
      details: '原始URL=${config.baseUrl}, 清理后URL=$cleanedBaseUrl, endpoint=$_generateContentEndpoint',
    );
  }

  String _cleanUrl(String url) {
    return url
        .trim()
        .replaceAll(RegExp(r'[,\s]+$'), '') // 去除末尾逗号和空格
        .replaceAll(RegExp(r'/+$'), ''); // 去除末尾多余斜杠
  }

  /// 单 Key / 无池端点的重试次数上限
  ///
  /// 这类厂商只有一把 Key，没有备用 Key 可切，只能靠时间退避穿越瞬时故障
  /// （TLS 握手中断、连接重置、网关 5xx 等），固定 3 次。
  static const int _genericMaxRetries = 3;

  /// 连接层瞬时故障的重试次数上限
  ///
  /// TLS 握手中断/连接重置多来自网关重连或证书冷启动，恢复常需数秒，
  /// 配合 [ApiKeyPool.getConnectionBackoffDelay] 的 1s/2s/4s/8s 退避，
  /// 总穿越窗口约 15 秒；HTTP 状态码类错误仍走 [_maxRetriesFor]。
  static const int _connectionMaxRetries = 5;

  /// connectTimeout 类故障的重试次数上限
  ///
  /// 与 [_connectionMaxRetries] 的区别：TLS 握手中断是「连上了又断」，重发多半
  /// 立刻见分晓，成本低故可多试；而 connectTimeout 是「整段窗口毫无响应」，
  /// 每次重试都要再付一次完整超时，且几乎注定打在同一个坏端点上。给 2 次已足够，
  /// 最坏等待 ≈ 2 × 12s + 退避 ≈ 27 秒。
  static const int _timeoutMaxRetries = 2;

  /// 连接层超时的单次等待上限
  ///
  /// 自配端点跨境访问时 RTT 抖动大；30 秒 connectTimeout 在故障时会实打实烧满
  /// 整段时长（5 次重试 ≈ 150 秒纯等待）。收紧到 12 秒，既能容忍网关冷启动与
  /// 跨境抖动，又能把最坏情况压缩到 5 × 12 ≈ 60 秒 + 退避（约 15 秒）以内。
  static const Duration _connectTimeoutForChat = Duration(seconds: 12);

  /// 单次请求的重试深度（按本次请求实际携带的密钥池大小决定）
  ///
  /// 多 Key 厂商（池 ≥2 把）每个请求本身就在换 Key，深度取池大小（封顶
  /// [ApiKeyPool.maxRotationAttempts]），让「换一把再试」有足够机会；
  /// 单 Key / 无池端点用 [_genericMaxRetries] 次纯退避重试。
  int _maxRetriesFor(_SendTrace trace) {
    final poolSize = trace.poolKeys.length;
    if (poolSize >= 2) {
      return poolSize.clamp(2, ApiKeyPool.maxRotationAttempts);
    }
    return _genericMaxRetries;
  }

  /// 统一的重试决策：判断本次失败是否值得重试，值得则按故障形态等待并给出归因
  ///
  /// Key 的更换不在这里发生 —— 每个请求在发出前已由 [_beginSend] 现取一把，
  /// 本函数只负责：把失败归类（是否 Key 作用域）、把冷却打在**本次真正发出去的**
  /// Key（[trace] 携带的 `sentKey`）上、以及决定这次重试前等多久。
  ///
  /// [hasDeliveredText] / [partiallyStreamed] 供流式场景使用：前者为「正文已吐给用户」，
  /// 是禁止重发的唯一条件；后者包含只吐过思考或工具参数的情况，重发前用 [onStreamRetry]
  /// 通知消费方作废本轮碎片（否则新旧两段会在「思考中」卡里首尾相接）。
  /// [onQuotaHold] 在整池冷却、需要排队等回填时回调预计等待时长。
  /// 返回 `true` 时调用方应 `retryCount++` 后 `continue` 重发本轮请求。
  ///
  /// 三类形态的差异化策略：
  /// - Key 作用域（429/401/403/配额文案）且池里还有别的 Key：冷却本次这把，
  ///   立刻换下一把重发（零退避，这才是多 Key 轮询的意义）；
  /// - 连接层瞬时故障（TLS 握手中断、连接重置）：[_connectionMaxRetries] 次、
  ///   1s/2s/4s/8s 退避；
  /// - connectTimeout：只给 [_timeoutMaxRetries] 次（整段窗口无响应，重试成本最高）。
  Future<bool> _shouldRetryAndWait(
    Object error,
    int retryCount, {
    bool hasDeliveredText = false,
    bool partiallyStreamed = false,
    void Function()? onStreamRetry,
    required _SendTrace trace,
    CancelToken? cancelToken,
    void Function(Duration hold)? onQuotaHold,
  }) async {
    // 只有**正文**已交付才禁止重发（重发=重复回答）。思考增量与工具参数不是交付物：
    // onToolCallsReady 还没被调用、UI 只有一张瞬态状态卡，而推理模型恰恰在这两段
    // 上流式时间最长，网关掐流也因此最常发生在这里。
    if (hasDeliveredText) {
      LoggerService.instance.logAI(
        '${trace.scene} 已输出正文后中断（${_briefError(error)}），'
        '重发会得到重复回答，放弃重试',
        level: LogLevel.warning,
      );
      return false;
    }

    final scene = trace.scene;
    final sentKey = trace.sentKey;
    final providerId = _config?.providerId;
    final hasProviderId = providerId != null && providerId.isNotEmpty;
    final isConnectionError = ApiKeyPool.isConnectionClassError(error);
    final isConnectTimeout =
        error is DioException && error.type == DioExceptionType.connectionTimeout;
    final keyScoped = ApiKeyPool.isKeyScopedError(error);
    final int maxRetries;
    if (isConnectTimeout) {
      maxRetries = _timeoutMaxRetries;
    } else if (isConnectionError) {
      maxRetries = _connectionMaxRetries;
    } else {
      maxRetries = _maxRetriesFor(trace);
    }

    if (retryCount >= maxRetries) {
      // 深度用尽也要留下一行事实：这把 Key 确实被限流/失效了，不记冷却就会被
      // 下一轮请求立刻再次端上来，白撞同一个 429。
      if (keyScoped && sentKey != null && hasProviderId) {
        ApiKeyPool.instance.markLimited(
          providerId,
          sentKey,
          cooldown: ApiKeyPool.instance.cooldownFromError(error),
        );
      }
      return false;
    }

    if (!ApiKeyPool.isRecoverableError(error)) {
      return false;
    }

    final next = retryCount + 1;

    // Key 作用域故障且池里还有别的 Key：冷却本次这把 + 换下一把重发。
    // 这是「一个厂商多把 Key」的核心收益：撞墙的 Key 不会拖死整条对话。
    if (keyScoped && sentKey != null && hasProviderId && trace.poolKeys.length >= 2) {
      final pool = ApiKeyPool.instance;
      pool.markLimited(
        providerId,
        sentKey,
        cooldown: pool.cooldownFromError(error),
      );
      pool.syncKeys(providerId, trace.poolKeys);
      if (!pool.hasAvailable(providerId, trace.poolKeys)) {
        // 整池都在冷却：排队等最早解锁的那把回填；等不到就放弃
        // （不可中断的排队会把「停止」响应拖到分钟级，所以有预算上限）
        final recovered = await _waitForKeyRecovery(
          providerId: providerId,
          trace: trace,
          cancelToken: cancelToken,
          onQuotaHold: onQuotaHold,
        );
        if (!recovered) return false;
      }
      if (partiallyStreamed) onStreamRetry?.call();
      LoggerService.instance.logAI(
        '$scene 撞上 Key 级故障（${_briefError(error)}），'
        '本次 Key ${ApiKeyPool.maskKey(sentKey)} 进入冷却，换下一把重发',
        level: LogLevel.warning,
      );
      return true;
    }

    final Duration delay = isConnectionError
        ? ApiKeyPool.getConnectionBackoffDelay(next)
        : ApiKeyPool.getBackoffDelay(next);
    LoggerService.instance.logAI(
      '$scene 遭遇瞬时故障（${_briefError(error)}），'
      '等待 ${delay.inMilliseconds}ms 后发起第 $next/$maxRetries 次重试',
      level: LogLevel.warning,
    );
    // 决定要重发了，才通知消费方作废本轮碎片：放在等待之前，让状态行立刻回到
    // 「小Q思考中」，而不是继续挂着上一段的半截思考
    if (partiallyStreamed) onStreamRetry?.call();
    await Future.delayed(delay);
    return true;
  }

  /// 整池冷却时排队等最早解锁的 Key 回填
  ///
  /// 返回 true 表示已有可用 Key（可重发）；预算内等不到（最早解锁时刻已超出
  /// [ApiKeyPool.maxPoolWait]）、或用户已点停止时返回 false。按 [_poolPollInterval]
  /// 切片轮询而不是 `Future.delayed(整段)`：一次提问有 3+ 轮请求，不可中断的排队
  /// 会把「停止」响应拖到分钟级。
  Future<bool> _waitForKeyRecovery({
    required String providerId,
    required _SendTrace trace,
    CancelToken? cancelToken,
    void Function(Duration hold)? onQuotaHold,
  }) async {
    final startedAt = DateTime.now();
    final budgetEnd = startedAt.add(ApiKeyPool.maxPoolWait);
    var announced = false;

    while (true) {
      if (cancelToken?.isCancelled == true) return false;
      final pool = ApiKeyPool.instance;
      // 判据必须是「还有没被冷却的 Key 可以用」，而不是「最早解锁的时刻」——
      // 整池里只要有一把是自由的就能立刻发信；拿解锁时刻做判据会被刚失败的这把
      // 顶到预算之外，明明有可用 Key 却误判成等不到。
      if (pool.hasAvailable(providerId, trace.poolKeys)) return true;
      final endAt = pool.earliestCooldownEnd(providerId);
      if (endAt == null) return true;
      final remaining = endAt.difference(DateTime.now());
      if (remaining <= Duration.zero) continue;
      if (endAt.isAfter(budgetEnd)) {
        LoggerService.instance.logAI(
          '${trace.scene} 整池冷却，最早解锁还需 ${remaining.inSeconds}s，'
          '超出排队预算 ${ApiKeyPool.maxPoolWait.inSeconds}s，放弃剩余重试',
          level: LogLevel.warning,
        );
        return false;
      }
      if (!announced) {
        announced = true;
        onQuotaHold?.call(remaining);
        LoggerService.instance.logAI(
          '${trace.scene} 整池冷却，排队 ${remaining.inSeconds}s 等待密钥回填',
          level: LogLevel.warning,
        );
      }
      await Future.delayed(_poolPollInterval);
    }
  }

  /// 整池冷却排队时的轮询切片
  static const Duration _poolPollInterval = Duration(milliseconds: 200);

  /// 每次真正发信前的准备：按厂商条目现取一把 Key 并起表
  ///
  /// 返回的 [_SendTrace] 同时携带本次实际使用的 Key 与厂商密钥池快照，而**不是**
  /// 各站点各自读取实例字段：`AiService` 是单例，主聊天、悬浮小Q、日记提取、
  /// 每日评分并发用它，任何「上次取到的 Key」这类实例字段都会串台。
  ///
  /// sentKey 为 null 表示「不覆写 header、沿用 [updateConfig] 写入的全局
  /// Authorization」，对应两种情况：单把 Key 的厂商（轮换无意义，全局 header 就是
  /// 这把）、锁定 Key 的连通性测试（[_pinApiKey]）。Key 列表每次读库（不做长活缓存）：
  /// WebDAV 同步 / 备份恢复会旁路服务直写库，缓存会让换设备后读到旧密钥。
  ///
  /// 这就是「即使成功了也要换下一把」的落点：取 Key 发生在请求发出前的一瞬，
  /// 与成功失败无关，所以整条 AgentLoop 的每一轮、以及并发的日记提取/每日评分
  /// 都各自拿一把，不再共享同一把、也不再互相覆写 Dio 的全局 header。
  Future<_SendTrace> _beginSend(String scene) async {
    final config = _config;
    if (config == null) {
      return _SendTrace(
        scene: scene,
        sentKey: null,
        poolKeys: const [],
        startedAt: DateTime.now(),
      );
    }

    var keys = const <String>[];
    if (!_pinApiKey && config.providerId.isNotEmpty) {
      keys = await _readProviderKeys(config.providerId);
    }

    String? sentKey;
    if (keys.length >= 2) {
      final pool = ApiKeyPool.instance;
      pool.syncKeys(config.providerId, keys);
      sentKey = pool.acquireNext(config.providerId, keys);
      LoggerService.instance.logAI(
        '$scene 本次发信 Key: ${sentKey == null ? '?' : ApiKeyPool.maskKey(sentKey)}',
        details: '厂商密钥池共 ${keys.length} 把',
      );
    }

    return _SendTrace(
      scene: scene,
      sentKey: sentKey,
      poolKeys: keys,
      startedAt: DateTime.now(),
    );
  }

  /// 测试注入：厂商密钥列表读取（生产走 [AiProviderRepository]）
  ///
  /// 有了它就能在纯单测里验证「每次请求实际发出的 Authorization 按池轮换」，
  /// 不必为了读一行密钥把 sqflite 整个拉进测试。
  @visibleForTesting
  static Future<List<String>> Function(String providerId)? providerKeysLoaderForTest;

  /// 读取厂商条目的密钥列表（读失败按「无池」处理，让请求走全局 header）
  Future<List<String>> _readProviderKeys(String providerId) async {
    final loader = providerKeysLoaderForTest;
    if (loader != null) {
      try {
        return await loader(providerId);
      } catch (_) {
        return const [];
      }
    }
    try {
      final provider = await AiProviderRepository.instance.getById(providerId);
      return (provider?.apiKeys ?? const <String>[])
          .where((key) => key.trim().isNotEmpty)
          .toList();
    } catch (e) {
      LoggerService.instance.logAI(
        '读取厂商密钥池失败: $e',
        level: LogLevel.warning,
      );
      return const [];
    }
  }

  /// 由本次真实使用的 Key 生成逐请求 header 覆写（null 交给 Dio 用全局 header）
  ///
  /// Gemini 走 `x-goog-api-key`、其余 OpenAI 兼容端点走 `Authorization`，
  /// 与 [updateConfig] 写全局 header 的分支保持一致。
  Map<String, dynamic>? _authOverride(String? key) {
    if (key == null) return null;
    if (_config?.provider == 'gemini') return {'x-goog-api-key': key};
    return {'Authorization': 'Bearer $key'};
  }

  /// 把请求头里的凭证换成掩码后再打印（失败诊断用）
  static Map<String, dynamic> _maskedHeaders(Map<String, dynamic> headers) {
    return headers.map((name, value) {
      final lower = name.toLowerCase();
      if (lower == 'authorization' || lower == 'x-goog-api-key') {
        final raw = value?.toString() ?? '';
        final token = raw.startsWith('Bearer ') ? raw.substring(7) : raw;
        return MapEntry(name, 'Bearer ${ApiKeyPool.maskKey(token)}');
      }
      return MapEntry(name, value);
    });
  }

  /// 替换底层 HTTP adapter（仅测试用）
  ///
  /// 有了它就能在不联网、也不改构造函数签名的前提下，断言「每次请求实际发出的
  /// Authorization」—— 这正是「多 Key 轮询」这条需求的直接回归锁。
  /// 刻意不给构造函数加 `Dio?` 参数：那会让「传入未配 BaseOptions 的 Dio」成为
  /// 一种合法的错误用法，而换 adapter 能保持超时/BaseOptions 语义与生产一致。
  @visibleForTesting
  set httpClientAdapterForTest(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
  }

  /// 单次 POST + 密钥池逐请求换 Key + 统一重试决策
  ///
  /// 给「原本没有自己的 while 循环、一次失败即抛」的长方法用（每日评分、设置页识图测试）：
  /// 它们此前既拿不到换 Key 也拿不到退避，现在与主链路共用同一套发信策略，
  /// 又不必把整段方法体重排一遍。
  Future<Response<T>> _postWithKeyRotation<T>(
    String endpoint, {
    required Object? data,
    required String scene,
    CancelToken? cancelToken,
  }) async {
    var retryCount = 0;
    while (true) {
      final trace = await _beginSend(scene);
      try {
        final response = await _dio.post<T>(
          endpoint,
          data: data,
          options: Options(headers: _authOverride(trace.sentKey)),
          cancelToken: cancelToken,
        );
        return response;
      } catch (e) {
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          trace: trace,
          cancelToken: cancelToken,
        )) {
          retryCount++;
          continue;
        }
        rethrow;
      }
    }
  }

  /// 把异常压成单行摘要，避免重试日志被堆栈刷屏
  String _briefError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  Future<String> chat(
    List<ChatMessage> messages, {
    CancelToken? cancelToken,
  }) async {
    final response = await chatResponse(messages, cancelToken: cancelToken);
    return response.content;
  }

  /// 支持 Tool Calling 的同步调用，返回完整 ChatMessage（含 content、toolCalls、thought 等）
  Future<ChatMessage> chatResponse(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始对话请求(带工具支持)',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}, 工具数=${tools?.length ?? 0}',
    );

    int retryCount = 0;

    while (true) {
      // 每次真正发信前现取一把 Key（成功也换）；非内置池端点返回 null，沿用全局 header
      final trace = await _beginSend('对话请求');
      final sentKey = trace.sentKey;
      try {
        String endpoint = _chatEndpoint;
        final bodyMap = await _prepareChatRequestBody(messages, stream: false, tools: tools);
        if (_config!.provider == 'gemini') {
          endpoint = '/v1beta/models/${_config!.modelName}:generateContent';
        }
        final dynamic requestBody = bodyMap;

        final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
        LoggerService.instance.logAI(
          'AI请求 [${_config!.provider}] [${_config!.modelName}] $endpoint'
          '${sentKey == null ? '' : ' [Key=${ApiKeyPool.maskKey(sentKey)}]'}:'
          '\n${_formatJsonForLogging(sanitizedBody)}',
        );

        final response = await _dio.post(
          endpoint,
          data: requestBody,
          options: Options(headers: _authOverride(sentKey)),
          cancelToken: cancelToken,
        );
        final duration = DateTime.now().difference(startTime).inMilliseconds;
        final data = response.data;
        LoggerService.instance.logAI('AI响应:\n${_formatJsonForLogging(data)}');

        String content = '';
        List<ToolCall>? toolCalls;

        if (_config!.provider == 'gemini') {
          content =
              data['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
        } else {
          final choice = data['choices']?[0];
          final message = choice?['message'] as Map<String, dynamic>?;
          content = message?['content'] as String? ?? '';
          
          if (message?['tool_calls'] != null && message!['tool_calls'] is List) {
            toolCalls = (message['tool_calls'] as List)
                .whereType<Map<String, dynamic>>()
                .map((m) => ToolCall.fromMap(m))
                .toList();
          }
        }

        LoggerService.instance.logAI(
          '对话完成',
          details: '耗时=${duration}ms, 响应长度=${content.length}字符, 工具调用数=${toolCalls?.length ?? 0}',
        );

        return ChatMessage(
          role: 'assistant',
          content: content,
          toolCalls: toolCalls,
          timestamp: DateTime.now(),
        );
      } catch (e, stackTrace) {
        // 用户主动中止（Dio CancelToken 触发）：直接抛出，禁止进入重试退避
        if (cancelToken?.isCancelled == true) rethrow;
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          trace: trace,
          cancelToken: cancelToken,
        )) {
          retryCount++;
          continue;
        }

        String details = stackTrace.toString();
        if (e is DioException) {
          final respData = e.response?.data;
          final reqData = e.requestOptions.data;
          final reqHeaders = e.requestOptions.headers;
          final sanitizedReqData = _sanitizeRequestBodyForLogging(reqData);
          debugPrint('=== AI REQUEST ERROR DIAGNOSTICS ===');
          debugPrint('URL: ${e.requestOptions.uri}');
          // 明文 Bearer Key 绝不能进日志：LoggerService 的敏感信息过滤器只管 base64 图片，
          // 而这里打的是 debugPrint 原始通道（内置池逐请求换 Key 后更要有掩码口径）
          debugPrint('Headers: ${_maskedHeaders(reqHeaders)}');
          debugPrint('Payload: ${_formatJsonForLogging(sanitizedReqData)}');
          debugPrint('Response Status: ${e.response?.statusCode}');
          if (respData != null) {
            debugPrint('Response Data: ${_formatJsonForLogging(respData)}');
          }
          debugPrint('====================================');
          if (respData != null) {
            details = 'Response Body: $respData\n\n$details';
          }
        }
        LoggerService.instance.logAI(
          '同步对话失败: $e',
          level: LogLevel.error,
          details: details,
        );
        rethrow;
      }
    }
  }

  /// 流式支持 Tool Calling 的高级流式调用
  ///
  /// - 当模型生成文本时，yield 文本增量片段（支持即时打字机效果）
  /// - 当模型生成 tool_calls 时，在内部聚合其参数碎片并周期性 yield 参数生成进度，
  ///   避免大参数（如 write_file 写大文件）生成期间 UI 无任何状态更新而形似卡死；
  ///   聚合完成后在 onToolCallsReady 回调中一次性交付完整对象
  /// [onQuotaHold] 在「整池限流、排队等额度回填」时回调预计等待时长，
  /// 供上层把它显示成状态行而不是让用户对着静止的「思考中」发呆。
  /// [onStreamRetry] 在**已经吐过思考或工具参数**、但本轮决定原地重发时回调一次，
  /// 供消费方作废本轮已渲染的碎片；正文一旦流出就不再重发，因此不会触发回调。
  Stream<AiToolStreamChunk> chatStreamWithTools({
    required List<ChatMessage> messages,
    List<Map<String, dynamic>>? tools,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
    void Function(Duration hold)? onQuotaHold,
    void Function()? onStreamRetry,
    CancelToken? cancelToken,
  }) async* {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始带工具的流式对话请求',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}, 工具数=${tools?.length ?? 0}',
    );

    int retryCount = 0;

    while (true) {
      // 两个口径分开记：正文决定**能不能**重发，是否流出过任何碎片决定重发前
      // 要不要通知消费方复位（网关掐流最常发生在只吐思考的阶段）
      bool hasDeliveredText = false;
      bool partiallyStreamed = false;
      // 每轮（含重试）都重新取一把 Key：这就是「成功也换」在 AgentLoop 每轮推理上的效果
      final trace = await _beginSend('带工具流式对话');
      final sentKey = trace.sentKey;
      try {
        final dynamic bodyMap = await _prepareChatRequestBody(messages, stream: true, tools: tools);
        final dynamic requestBody = jsonEncode(bodyMap);

        final response = await _dio.post<ResponseBody>(
          _chatEndpoint,
          data: requestBody,
          options: Options(
            responseType: ResponseType.stream,
            headers: _authOverride(sentKey),
          ),
          cancelToken: cancelToken,
        );

        final stream = response.data?.stream;
        if (stream == null) {
          LoggerService.instance.logAI('流式响应为空', level: LogLevel.warning);
          return;
        }

        String buffer = '';
        final accumulatedResponse = StringBuffer();
        // 存储流式拼接中的 tool_calls: index -> {id, name, argumentsBuffer}
        final Map<int, Map<String, dynamic>> toolCallBuilders = {};
        // 参数生成进度上报的节流时间点（跨工具共享，首次上报不受节流限制）
        DateTime? lastProgressAt;

        await for (final chunk in stream) {
          buffer += utf8.decode(chunk, allowMalformed: true);
          final lines = buffer.split('\n');
          buffer = lines.removeLast();

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
            final data = trimmed.substring(5).trim();
            if (data == '[DONE]') {
              final duration = DateTime.now().difference(startTime).inMilliseconds;
              LoggerService.instance.logAI(
                'AI带工具流式响应完成 [耗时=${duration}ms]:\n$accumulatedResponse',
              );
              _deliverToolCalls(toolCallBuilders, onToolCallsReady);
              return;
            }

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              // 捕获商汤等服务商在流式第一包中下发的 JSON 错误对象。
              // 必须保留**整个** error 对象而不是只取 message：网关的 `code: 8`
              // （rps 突发）与 `EndpointTPMExceeded`（额度耗尽）要靠 code 分流，
              // 只留 message 会让两种形态长得一模一样。
              if (json.containsKey('error')) {
                throw Exception('AI Stream Error: ${json['error']}');
              }

              // usage 末帧（choices 为空数组）：仅作流式解析标记，不再落库
              // （历史 ai_request_stats 诊断表已随厂商条目重构移除）

              final choice = json['choices']?[0];
              final delta = choice?['delta'] as Map<String, dynamic>?;

              // 首个可见增量即为「用户等了多久才开始看到东西」，是换 Key 策略
              // 最关心的指标（前缀缓存被轮换打掉时会首先反映在这里）
              if ((delta?['content'] is String && (delta!['content'] as String).isNotEmpty) ||
                  (delta?['reasoning_content'] is String &&
                      (delta!['reasoning_content'] as String).isNotEmpty) ||
                  (delta?['reasoning'] is String &&
                      (delta!['reasoning'] as String).isNotEmpty) ||
                  delta?['tool_calls'] is List) {
              }

              // 0. 思考/推理增量：智谱 GLM、DeepSeek reasoner 等用 reasoning_content，
              //    SenseNova 用 reasoning；供「思考中」状态卡实时滚动展示
              final reasoning =
                  (delta?['reasoning_content'] ?? delta?['reasoning']) as String?;
              if (reasoning != null && reasoning.isNotEmpty) {
                partiallyStreamed = true;
                yield AiToolStreamChunk.reasoning(reasoning);
              }

              // 1. 文本内容增量
              final text = delta?['content'] as String?;
              if (text != null && text.isNotEmpty) {
                accumulatedResponse.write(text);
                hasDeliveredText = true;
                partiallyStreamed = true;
                yield AiToolStreamChunk.text(text);
              }

              // 2. 工具调用碎片聚合
              final toolCallsDelta = delta?['tool_calls'] as List?;
              if (toolCallsDelta != null) {
                for (final tc in toolCallsDelta) {
                  if (tc is! Map<String, dynamic>) continue;
                  final idx = tc['index'] as int? ?? 0;
                  final builder = toolCallBuilders.putIfAbsent(idx, () => {
                    'id': '',
                    'name': '',
                    'arguments': StringBuffer(),
                  });

                  if (tc['id'] != null) {
                    builder['id'] = (builder['id'] as String) + (tc['id'] as String);
                  }
                  final func = tc['function'] as Map<String, dynamic>?;
                  if (func != null) {
                    if (func['name'] != null) {
                      builder['name'] = (builder['name'] as String) + (func['name'] as String);
                    }
                    if (func['arguments'] != null) {
                      (builder['arguments'] as StringBuffer).write(func['arguments']);
                    }
                  }

                  // 参数生成进度上报：参数已开始流出说明工具名必已完整，
                  // 首次立即上报让 UI 尽快切到工具状态，此后 500ms 节流
                  final name = builder['name'] as String;
                  final argsBuffer = builder['arguments'] as StringBuffer;
                  if (name.isNotEmpty && argsBuffer.isNotEmpty) {
                    final now = DateTime.now();
                    final isFirstProgress = builder['progressNotified'] != true;
                    if (isFirstProgress ||
                        now.difference(lastProgressAt!).inMilliseconds >= 500) {
                      builder['progressNotified'] = true;
                      lastProgressAt = now;
                      partiallyStreamed = true;
                      yield AiToolStreamChunk.toolProgress(
                        ToolCallProgress(
                          toolName: name,
                          partialArguments: argsBuffer.toString(),
                        ),
                      );
                    }
                  }
                }
              }
            } catch (e) {
              // 若已进入显式错误，直接抛出交由外层重试判断
              if (e.toString().contains('AI Stream Error:')) {
                rethrow;
              }
            }
          }
        }

        // 流自然结束但没有 [DONE]（部分网关会这样收流）：同样算一次成功发信
        _deliverToolCalls(toolCallBuilders, onToolCallsReady);
        return;
      } catch (e, stackTrace) {
        // 用户主动中止（Dio CancelToken 触发）：直接抛出，禁止进入重试退避
        if (cancelToken?.isCancelled == true) rethrow;
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          hasDeliveredText: hasDeliveredText,
          partiallyStreamed: partiallyStreamed,
          onStreamRetry: onStreamRetry,
          trace: trace,
          cancelToken: cancelToken,
          onQuotaHold: onQuotaHold,
        )) {
          retryCount++;
          continue;
        }
        LoggerService.instance.logAI(
          '带工具流式对话失败: $e',
          level: LogLevel.error,
          details: stackTrace.toString(),
        );
        rethrow;
      }
    }
  }

  void _deliverToolCalls(
    Map<int, Map<String, dynamic>> toolCallBuilders,
    void Function(List<ToolCall> toolCalls)? onToolCallsReady,
  ) {
    if (toolCallBuilders.isEmpty || onToolCallsReady == null) return;
    final List<ToolCall> completedCalls = [];
    for (final b in toolCallBuilders.values) {
      final id = b['id'] as String? ?? 'call_${DateTime.now().millisecondsSinceEpoch}';
      final name = b['name'] as String? ?? '';
      final argsStr = (b['arguments'] as StringBuffer).toString();
      Map<String, dynamic> args = {};
      try {
        if (argsStr.trim().isNotEmpty) {
          args = jsonDecode(argsStr) as Map<String, dynamic>;
        }
      } catch (_) {}
      completedCalls.add(ToolCall(id: id, name: name, arguments: args));
    }
    if (completedCalls.isNotEmpty) {
      onToolCallsReady(completedCalls);
    }
  }

  Stream<String> chatStream(List<ChatMessage> messages) async* {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始流式对话请求',
      details: '模型=${_config!.modelName}, 消息数=${messages.length}',
    );

    int retryCount = 0;

    while (true) {
      bool hasDeliveredText = false;
      final trace = await _beginSend('普通流式对话');
      final sentKey = trace.sentKey;
      try {
        final dynamic bodyMap = await _prepareChatRequestBody(messages, stream: true);
        final dynamic requestBody = jsonEncode(bodyMap);

        final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
        LoggerService.instance.logAI(
          'AI流式请求 [${_config!.provider}] [${_config!.modelName}] $_chatEndpoint'
          '${sentKey == null ? '' : ' [Key=${ApiKeyPool.maskKey(sentKey)}]'}:'
          '\n${_formatJsonForLogging(sanitizedBody)}',
        );

        final response = await _dio.post<ResponseBody>(
          _chatEndpoint,
          data: requestBody,
          options: Options(
            responseType: ResponseType.stream,
            headers: _authOverride(sentKey),
          ),
        );

        final stream = response.data?.stream;
        if (stream == null) {
          LoggerService.instance.logAI('流式响应为空', level: LogLevel.warning);
          return;
        }

        String buffer = '';
        int totalChars = 0;
        final accumulatedResponse = StringBuffer();
        await for (final chunk in stream) {
          buffer += utf8.decode(chunk, allowMalformed: true);
          final lines = buffer.split('\n');
          buffer = lines.removeLast();

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
            final data = trimmed.substring(5).trim();
            if (data == '[DONE]') {
              final duration = DateTime.now()
                  .difference(startTime)
                  .inMilliseconds;
              LoggerService.instance.logAI(
                'AI流式响应完成 [总输出=$totalChars字符] [耗时=${duration}ms]:\n$accumulatedResponse',
              );
              return;
            }

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              if (json.containsKey('error')) {
                final errObj = json['error'];
                final errMsg = errObj is Map ? (errObj['message'] ?? errObj.toString()) : errObj.toString();
                throw Exception('AI Stream Error: $errMsg');
              }

              String? text;
              if (_config!.provider == 'gemini') {
                text = json['candidates']?[0]?['content']?['parts']?[0]?['text'];
              } else {
                text = json['choices']?[0]?['delta']?['content'];
              }
              if (text != null) {
                totalChars += text.length;
                accumulatedResponse.write(text);
                hasDeliveredText = true;
                yield text;
              }
            } catch (e) {
              if (e.toString().contains('AI Stream Error:')) {
                rethrow;
              }
            }
          }
        }

        final duration = DateTime.now().difference(startTime).inMilliseconds;
        LoggerService.instance.logAI(
          'AI流式响应结束 [总输出=$totalChars字符] [耗时=${duration}ms]:\n$accumulatedResponse',
        );
        return;
      } catch (e, stackTrace) {
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          hasDeliveredText: hasDeliveredText,
          trace: trace,
        )) {
          retryCount++;
          continue;
        }

        String details = stackTrace.toString();
        if (e is DioException) {
          final respData = e.response?.data;
          if (respData != null) {
            details = 'Response Body: $respData\n\n$details';
          }
        }
        LoggerService.instance.logAI(
          '流式对话失败: $e',
          level: LogLevel.error,
          details: details,
        );
        rethrow;
      }
    }
  }

  String get _chatEndpoint {
    if (_config!.provider == 'gemini') {
      return 'v1beta/models/${_config!.modelName}:streamGenerateContent?alt=sse';
    }
    final baseUrl = _config!.baseUrl;
    if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/v1/')) {
      return 'chat/completions';
    }
    return 'v1/chat/completions';
  }

  String get _generateContentEndpoint {
    if (_config!.provider == 'gemini') {
      return 'v1beta/models/${_config!.modelName}:generateContent';
    }
    final baseUrl = _config!.baseUrl;
    if (baseUrl.endsWith('/v1') || baseUrl.endsWith('/v1/')) {
      return 'chat/completions';
    }
    return 'v1/chat/completions';
  }

  /// 统一构建普通对话与流式对话的请求体，兼容多模态图片输入与不同供应商协议
  Future<dynamic> _prepareChatRequestBody(
    List<ChatMessage> messages, {
    bool stream = false,
    List<Map<String, dynamic>>? tools,
  }) async {
    final imageRepo = ImageRepository();

    if (_config!.provider == 'gemini') {
      String? systemInstruction;
      final List<Map<String, dynamic>> contents = [];

      for (final m in messages) {
        if (m.role == 'system') {
          systemInstruction = m.content;
        } else {
          final role = m.role == 'user' ? 'user' : 'model';
          final parts = <Map<String, dynamic>>[
            {'text': m.content},
          ];

          if (m.images != null && m.images!.isNotEmpty) {
            for (final imgPath in m.images!) {
              try {
                String b64 = '';
                String mime = ImageRepository.getMimeType(imgPath);
                if (imgPath.startsWith('data:')) {
                  final commaIdx = imgPath.indexOf(',');
                  if (commaIdx != -1) {
                    b64 = imgPath.substring(commaIdx + 1);
                    final header = imgPath.substring(5, commaIdx);
                    if (header.contains(';')) {
                      mime = header.split(';').first;
                    }
                  }
                } else {
                  b64 = await imageRepo.getBase64Image(imgPath);
                }
                if (b64.isNotEmpty) {
                  parts.add({
                    'inline_data': {'mime_type': mime, 'data': b64},
                  });
                }
              } catch (e) {
                LoggerService.instance.logAI(
                  '加载Gemini多模态图片失败: $imgPath, error=$e',
                  level: LogLevel.warning,
                );
              }
            }
          }

          contents.add({
            'role': role,
            'parts': parts,
          });
        }
      }

      final bodyMap = <String, dynamic>{
        'contents': contents,
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
        },
      };
      if (systemInstruction != null) {
        bodyMap['systemInstruction'] = {
          'parts': [
            {'text': systemInstruction},
          ],
        };
      }
      return bodyMap;
    }

    final isOmni = _config!.modelName.toLowerCase().contains('omni');
    final formattedMessages = <Map<String, dynamic>>[];

    for (final m in messages) {
      if (m.role == 'tool') {
        // 工具执行结果消息 (OpenAI Tool Role)
        formattedMessages.add({
          'role': 'tool',
          'tool_call_id': m.toolCallId ?? '',
          'content': m.content,
        });
        continue;
      }

      if (m.role == 'assistant' && m.toolCalls != null && m.toolCalls!.isNotEmpty) {
        // 含有工具调用的助手消息
        formattedMessages.add({
          'role': 'assistant',
          'content': m.content.isEmpty ? null : m.content,
          'tool_calls': m.toolCalls!.map((t) => t.toMap()).toList(),
        });
        continue;
      }

      final hasImages = m.images != null && m.images!.isNotEmpty;
      if (isOmni) {
        final contentList = <Map<String, dynamic>>[
          {'type': 'text', 'text': m.content},
        ];
        if (hasImages) {
          final b64List = <String>[];
          for (final imgPath in m.images!) {
            try {
              String b64 = '';
              if (imgPath.startsWith('data:')) {
                final commaIdx = imgPath.indexOf(',');
                if (commaIdx != -1) b64 = imgPath.substring(commaIdx + 1);
              } else {
                b64 = await imageRepo.getBase64Image(imgPath);
              }
              if (b64.isNotEmpty) b64List.add(b64);
            } catch (_) {}
          }
          if (b64List.isNotEmpty) {
            contentList.add({
              'type': 'input_image',
              'input_image': {
                'type': 'base64',
                'data': b64List,
              },
            });
          }
        }
        formattedMessages.add({
          'role': m.role,
          'content': contentList,
        });
      } else if (hasImages) {
        final contentList = <Map<String, dynamic>>[
          if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
        ];
        for (final imgPath in m.images!) {
          try {
            String b64 = '';
            String mime = ImageRepository.getMimeType(imgPath);
            if (imgPath.startsWith('data:')) {
              final commaIdx = imgPath.indexOf(',');
              if (commaIdx != -1) {
                b64 = imgPath.substring(commaIdx + 1);
                final header = imgPath.substring(5, commaIdx);
                if (header.contains(';')) {
                  mime = header.split(';').first;
                }
              }
            } else {
              b64 = await imageRepo.getBase64Image(imgPath);
            }
            if (b64.isNotEmpty) {
              contentList.add({
                'type': 'image_url',
                'image_url': {'url': 'data:$mime;base64,$b64'},
              });
            }
          } catch (e) {
            LoggerService.instance.logAI(
              '加载图片失败: $imgPath, error=$e',
              level: LogLevel.warning,
            );
          }
        }
        formattedMessages.add({
          'role': m.role,
          'content': contentList,
        });
      } else {
        formattedMessages.add({'role': m.role, 'content': m.content});
      }
    }

    final bodyMap = _buildBaseBody(messages: formattedMessages, stream: stream, tools: tools);
    if (isOmni) {
      bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch.toString();
      bodyMap['output_modalities'] = ['text'];
    }
    return bodyMap;
  }

  /// 构建 OpenAI 兼容接口的基础请求体，统一注入通用参数。
  Map<String, dynamic> _buildBaseBody({
    required List<dynamic> messages,
    bool stream = false,
    Map<String, dynamic>? responseFormat,
    List<Map<String, dynamic>>? tools,
  }) {
    final body = <String, dynamic>{
      'model': _config!.modelName,
      'messages': messages,
      'temperature': _temperature,
      'max_tokens': _maxTokens,
    };
    if (stream) body['stream'] = true;
    if (responseFormat != null) body['response_format'] = responseFormat;
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = 'auto';
    }
    if (_reasoningEffort != null) {
      body['reasoning_effort'] = _reasoningEffort;
    }
    return body;
  }

  /// 根据配置推断默认推理强度。
  ///
  /// 优先级：vendorId 匹配 > baseUrl 匹配 > modelName 匹配
  String? _resolveReasoningEffort(AiConfig config) {
    // 1. 优先通过 vendorId 匹配
    if (config.vendorId != null) {
      final providerConfig = getProviderById(config.vendorId!);
      if (providerConfig?.defaultReasoningEffort != null) {
        return providerConfig!.defaultReasoningEffort;
      }
    }

    // 2. 通过 baseUrl 匹配
    final baseUrl = config.baseUrl.toLowerCase();
    for (final provider in aiProviders) {
      if (provider.defaultReasoningEffort == null) continue;
      final providerUrl = provider.defaultBaseUrl.toLowerCase();
      if (providerUrl.isNotEmpty && baseUrl.contains(providerUrl.replaceAll('https://', '').replaceAll('http://', ''))) {
        return provider.defaultReasoningEffort;
      }
    }

    // 3. 通过 modelName 匹配
    final modelName = config.modelName.toLowerCase();
    for (final provider in aiProviders) {
      if (provider.defaultReasoningEffort == null) continue;
      for (final model in provider.models) {
        if (modelName == model.toLowerCase()) {
          return provider.defaultReasoningEffort;
        }
      }
    }

    return null;
  }

  Future<String> generateDiarySummary(String diaryContent) async {
    LoggerService.instance.logAI(
      '生成日记摘要',
      details: '输入长度=${diaryContent.length}字符',
    );

    final messages = [
      ChatMessage(
        role: 'system',
        content:
            'You are a helpful assistant that summarizes diary entries. '
            'Provide a concise and insightful summary of the diary content.',
      ),
      ChatMessage(role: 'user', content: diaryContent),
    ];
    return await chat(messages);
  }

  Future<String> analyzeMood(String diaryContent) async {
    LoggerService.instance.logAI(
      '分析心情状态',
      details: '输入长度=${diaryContent.length}字符',
    );

    final messages = [
      ChatMessage(
        role: 'system',
        content:
            'You are a mood analysis assistant. Analyze the emotional tone '
            'of the diary entry and provide a brief mood assessment.',
      ),
      ChatMessage(role: 'user', content: diaryContent),
    ];
    return await chat(messages);
  }

  Future<String> generateTodoSuggestions(String context) async {
    LoggerService.instance.logAI(
      '生成待办建议',
      details: '上下文长度=${context.length}字符',
    );

    final messages = [
      ChatMessage(
        role: 'system',
        content:
            'You are a productivity assistant. Based on the provided context, '
            'suggest actionable todo items.',
      ),
      ChatMessage(role: 'user', content: context),
    ];
    return await chat(messages);
  }

  Map<String, dynamic> _parseSimplifiedTime(String t) {
    final result = <String, dynamic>{};

    if (t.contains('~')) {
      final parts = t.split('~');
      final startPart = parts[0];
      final endPart = parts[1];

      if (startPart.isNotEmpty) {
        if (startPart.startsWith('-')) {
          result['start'] = startPart.substring(1);
          result['startOffset'] = -1;
        } else {
          result['start'] = startPart;
        }
      }

      if (endPart.isNotEmpty) {
        if (endPart.startsWith('-')) {
          result['end'] = endPart.substring(1);
          result['endOffset'] = -1;
        } else {
          result['end'] = endPart;
          result['endOffset'] = 0;
        }
      }
    } else {
      if (t.startsWith('-')) {
        result['start'] = t.substring(1);
        result['startOffset'] = -1;
      } else {
        result['start'] = t;
      }
    }

    return result;
  }

  Map<String, dynamic> _convertSimplifiedExtractResult(
    Map<String, dynamic> simplified,
  ) {
    final result = <String, dynamic>{};

    result['shortcutId'] = simplified['id'] ?? simplified['shortcutId'];

    if (simplified.containsKey('t')) {
      result['time'] = _parseSimplifiedTime(simplified['t'] as String);
    } else if (simplified.containsKey('time')) {
      final timeVal = simplified['time'];
      if (timeVal is String) {
        result['time'] = _parseSimplifiedTime(timeVal);
      } else if (timeVal is Map) {
        result['time'] = timeVal;
      } else {
        result['time'] = {};
      }
    } else {
      result['time'] = {};
    }

    result['fields'] = simplified['f'] ?? simplified['fields'] ?? {};

    result['notes'] = simplified['n'] ?? simplified['notes'] ?? '';

    if (simplified.containsKey('date')) {
      result['date'] = simplified['date'];
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> extractUnified({
    String? text,
    String? imageBase64,
    String? mimeType,
    required String schema,
    String? contextStr,
    CancelToken? cancelToken,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    final hasImage = imageBase64 != null && imageBase64.isNotEmpty;
    final hasText = text != null && text.isNotEmpty;

    String inputType;
    if (hasImage && hasText) {
      inputType = '图文';
    } else if (hasImage) {
      inputType = '图片';
    } else {
      inputType = '文本';
    }

    LoggerService.instance.logAI(
      '统一提取请求',
      details: '类型=$inputType, 有文本=$hasText, 有图片=$hasImage',
    );

    var systemPrompt = defaultSystemPrompts['unified_extraction'] ?? '';
    systemPrompt = systemPrompt
        .replaceAll('{{contextStr}}', contextStr ?? '')
        .replaceAll('{{schema}}', schema);

    dynamic requestBody;

    if (hasImage) {
      requestBody = _buildMultimodalRequestBody(
        systemPrompt: systemPrompt,
        imageBase64: imageBase64,
        mimeType: mimeType ?? 'image/jpeg',
        text: text,
        inputType: inputType,
      );
    } else {
      final userMessageText = '[用户输入] ($inputType)\n${text ?? ''}';
      if (_config!.provider == 'gemini') {
        requestBody = {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': userMessageText},
              ],
            },
          ],
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt},
            ],
          },
          'generationConfig': {
            'temperature': _temperature,
            'maxOutputTokens': _maxTokens,
            'responseMimeType': 'application/json',
          },
        };
      } else {
        final isOmni = _config!.modelName.toLowerCase().contains('omni');
        final formattedMessages = [
          if (isOmni) ...[
            {
              'role': 'system',
              'content': [
                {'type': 'text', 'text': systemPrompt},
              ],
            },
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': userMessageText},
              ],
            },
          ] else ...[
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMessageText},
          ],
        ];

        final bodyMap = _buildBaseBody(
          messages: formattedMessages,
          responseFormat: {'type': 'json_object'},
        );

        if (isOmni) {
          bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch
              .toString();
          bodyMap['output_modalities'] = ['text'];
        }

        requestBody = bodyMap;
      }
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI统一提取请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    int retryCount = 0;

    while (true) {
      // 每次发信前现取一把 Key：日记提取与主聊天共用同一个 AiService 单例，
      // 只有逐请求覆写 header 才不会互相串台
      final trace = await _beginSend('日记统一提取');
      final sentKey = trace.sentKey;
      try {
        final response = await _dio.post(
          _generateContentEndpoint,
          data: requestBody,
          options: Options(headers: _authOverride(sentKey)),
          cancelToken: cancelToken,
        );
        // 检测推理模型是否因 max_tokens 不足导致输出截断
        final finishReason = _extractFinishReason(response.data);
        if (finishReason == 'length') {
          LoggerService.instance.logAI(
            '⚠️ AI响应被截断 (finish_reason: length)，当前 max_tokens=$_maxTokens 可能不够推理模型使用',
            level: LogLevel.warning,
          );
        }

        final content = _extractTextFromResponse(response.data);
        LoggerService.instance.logAI(
          'AI统一提取响应:\n${_formatJsonForLogging(response.data)}',
        );

        final jsonResult = _parseJsonFromAiContent(content);
        LoggerService.instance.logAI(
          '统一提取完成',
          details: '结果数量=${jsonResult is List ? jsonResult.length : 1}',
        );

        List<Map<String, dynamic>> results;
        if (jsonResult is List) {
          results = jsonResult.cast<Map<String, dynamic>>();
        } else if (jsonResult is Map<String, dynamic>) {
          if (jsonResult['message'] == 'NO_USEFUL_INFO') {
            LoggerService.instance.logAI(
              '统一提取完成',
              details: 'AI返回NO_USEFUL_INFO，未提取到有用信息',
            );
            return [];
          }
          List<Map<String, dynamic>>? foundList;
          if (jsonResult['tags'] is List &&
              (jsonResult['tags'] as List).every((e) => e is Map)) {
            foundList = (jsonResult['tags'] as List).cast<Map<String, dynamic>>();
          } else if (jsonResult['results'] is List &&
              (jsonResult['results'] as List).every((e) => e is Map)) {
            foundList = (jsonResult['results'] as List)
                .cast<Map<String, dynamic>>();
          } else {
            for (final entry in jsonResult.entries) {
              final val = entry.value;
              if (val is List && val.every((e) => e is Map)) {
                foundList = val.cast<Map<String, dynamic>>();
                break;
              }
            }
          }
          if (foundList != null) {
            results = foundList;
          } else {
            results = [jsonResult];
          }
        } else {
          results = [];
        }

        if (results.isEmpty) {
          LoggerService.instance.logAI(
            '统一提取完成',
            details: '结果为空，未提取到有用信息',
          );
          return [];
        }

        return results.map(_convertSimplifiedExtractResult).toList();
      } catch (e, stackTrace) {
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          trace: trace,
          cancelToken: cancelToken,
        )) {
          retryCount++;
          continue;
        }
        LoggerService.instance.logAI(
          '统一提取失败: $e',
          level: LogLevel.error,
          details: stackTrace.toString(),
        );
        rethrow;
      }
    }
  }

  /// 多模态对话：发送图片+文本，返回纯文本响应（不强制 JSON 格式）。
  ///
  /// 用于笔记图片内容识别等场景，与 [extractUnified] 的区别在于：
  /// - 不强制 `response_format: json_object` / `responseMimeType: application/json`
  /// - 直接返回模型的纯文本输出，由调用方自行处理
  Future<String> chatWithImage({
    required String imageBase64,
    required String mimeType,
    String? userText,
    String? systemPrompt,
    CancelToken? cancelToken,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    final startTime = DateTime.now();
    LoggerService.instance.logAI(
      '开始图片识别请求',
      details: '模型=${_config!.modelName}, 有文本=${userText != null && userText.isNotEmpty}',
    );

    final requestBody = _buildImageChatRequestBody(
      systemPrompt: systemPrompt ?? '',
      imageBase64: imageBase64,
      mimeType: mimeType,
      text: userText,
    );

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      '图片识别请求 [${_config!.provider}] [${_config!.modelName}] $_generateContentEndpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    int retryCount = 0;

    while (true) {
      final trace = await _beginSend('图片识别');
      final sentKey = trace.sentKey;
      try {
        final response = await _dio.post(
          _generateContentEndpoint,
          data: requestBody,
          options: Options(headers: _authOverride(sentKey)),
          cancelToken: cancelToken,
        );
        final result = _extractTextFromResponse(response.data);
        LoggerService.instance.logAI(
          '图片识别响应:\n${_formatJsonForLogging(response.data)}',
        );
        LoggerService.instance.logAI(
          '图片识别完成',
          details: '耗时=${DateTime.now().difference(startTime).inMilliseconds}ms, 响应长度=${result.length}字符',
        );
        return result;
      } catch (e, stackTrace) {
        if (await _shouldRetryAndWait(
          e,
          retryCount,
          trace: trace,
          cancelToken: cancelToken,
        )) {
          retryCount++;
          continue;
        }

        String details = stackTrace.toString();
        if (e is DioException) {
          final respData = e.response?.data;
          if (respData != null) {
            details = 'Response Body: $respData\n\n$details';
          }
        }
        LoggerService.instance.logAI(
          '图片识别失败: $e',
          level: LogLevel.error,
          details: details,
        );
        rethrow;
      }
    }
  }

  /// 构建多模态对话请求体（自由文本输出，不强制 JSON）。
  ///
  /// 结构与 [_buildMultimodalRequestBody] 一致，但去掉了 `response_format` /
  /// `responseMimeType` 约束，让模型自由输出文本。
  Map<String, dynamic> _buildImageChatRequestBody({
    required String systemPrompt,
    required String imageBase64,
    required String mimeType,
    String? text,
  }) {
    final userMessageText = text ?? '';
    if (_config!.provider == 'gemini') {
      final parts = <Map<String, dynamic>>[
        if (userMessageText.isNotEmpty) {'text': userMessageText},
        {
          'inline_data': {'mime_type': mimeType, 'data': imageBase64},
        },
      ];
      return {
        'contents': [
          {
            'role': 'user',
            'parts': parts,
          },
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
        },
      };
    }

    final isOmni = _config!.modelName.toLowerCase().contains('omni');
    if (isOmni) {
      return {
        'model': _config!.modelName,
        'messages': [
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              if (userMessageText.isNotEmpty)
                {'type': 'text', 'text': userMessageText},
              {
                'type': 'input_image',
                'input_image': {
                  'type': 'base64',
                  'data': [imageBase64],
                },
              },
            ],
          },
        ],
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'sessionId': DateTime.now().millisecondsSinceEpoch.toString(),
        'output_modalities': ['text'],
      };
    }

    return _buildBaseBody(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {
          'role': 'user',
          'content': [
            if (userMessageText.isNotEmpty)
              {'type': 'text', 'text': userMessageText},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mimeType;base64,$imageBase64'},
            },
          ],
        },
      ],
    );
  }

  Map<String, dynamic> _buildMultimodalRequestBody({
    required String systemPrompt,
    required String imageBase64,
    required String mimeType,
    String? text,
    required String inputType,
  }) {
    final userMessageText = '[用户输入] ($inputType)\n${text ?? ''}';
    if (_config!.provider == 'gemini') {
      return {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': userMessageText},
              {
                'inline_data': {'mime_type': mimeType, 'data': imageBase64},
              },
            ],
          },
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
          'responseMimeType': 'application/json',
        },
      };
    }

    final isOmni = _config!.modelName.toLowerCase().contains('omni');
    if (isOmni) {
      return {
        'model': _config!.modelName,
        'messages': [
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userMessageText},
              {
                'type': 'input_image',
                'input_image': {
                  'type': 'base64',
                  'data': [imageBase64],
                },
              },
            ],
          },
        ],
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'sessionId': DateTime.now().millisecondsSinceEpoch.toString(),
        'output_modalities': ['text'],
      };
    }

    return _buildBaseBody(
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': userMessageText},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mimeType;base64,$imageBase64'},
            },
          ],
        },
      ],
      responseFormat: {'type': 'json_object'},
    );
  }

  String _extractTextFromResponse(dynamic data) {
    // 如果 data 本身就是字符串，直接返回（可能是未自动解析的 JSON 或纯文本响应）
    if (data is String) {
      return data;
    }
    if (data is! Map<String, dynamic>) {
      LoggerService.instance.logAI(
        'AI响应数据格式异常: ${data.runtimeType}',
        level: LogLevel.warning,
      );
      return '';
    }

    if (_config!.provider == 'gemini') {
      final candidates = data['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final content = candidates[0]?['content'];
        if (content is Map) {
          final parts = content['parts'];
          if (parts is List && parts.isNotEmpty) {
            return parts[0]?['text']?.toString() ?? '';
          }
        }
      }
      return '';
    }

    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = choices[0]?['message'];
      if (message is Map) {
        final content = message['content']?.toString();
        if (content != null && content.isNotEmpty) {
          return content;
        }
        // 推理模型（如 DeepSeek-R1、SenseNova）可能把答案放在 reasoning 中
        // 当 max_tokens 不够时 content 可能为空，回退到 reasoning
        final reasoning = message['reasoning']?.toString();
        if (reasoning != null && reasoning.isNotEmpty) {
          return reasoning;
        }
        final reasoningContent = message['reasoning_content']?.toString();
        if (reasoningContent != null && reasoningContent.isNotEmpty) {
          return reasoningContent;
        }
        return '';
      }
    }
    return '';
  }

  /// 从响应数据中提取 finish_reason，用于检测 max_tokens 截断
  String? _extractFinishReason(dynamic data) {
    if (data is! Map<String, dynamic>) return null;
    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty) {
      return choices[0]?['finish_reason']?.toString();
    }
    return null;
  }

  dynamic _parseJsonFromAiContent(String content) {
    final stripped = _stripMarkdownCodeBlock(content);
    try {
      return jsonDecode(stripped);
    } catch (e) {
      // 当标准解析失败时，记录警告并尝试使用正则/括号定位提取 JSON 子字符串进行二次解析
      LoggerService.instance.logAI(
        'AI响应标准JSON解析失败，尝试提取JSON子串。原始内容:\n$content',
        level: LogLevel.warning,
      );
      // 部分模型（如 Gemini）输出的 JSON 字符串值中含未转义的原始换行符，
      // 严格解析会抛 "Control character in string"，先修复再重试
      try {
        return jsonDecode(_sanitizeJsonControlChars(stripped));
      } catch (_) {}
      try {
        final extracted = _extractJsonString(content);
        if (extracted != null) {
          return jsonDecode(_sanitizeJsonControlChars(extracted));
        }
      } catch (innerError) {
        LoggerService.instance.logAI(
          '提取JSON子串并解析依然失败: $innerError',
          level: LogLevel.error,
        );
      }
      rethrow;
    }
  }

  /// 修复 JSON 字符串字面量中未转义的控制字符。
  ///
  /// 按字符扫描并跟踪是否位于字符串内部（正确处理 `\"` 转义与中文引号不受影响），
  /// 将字符串值中的裸控制字符（换行、回车、制表符及其他 <0x20 字符）替换为
  /// 合法的转义序列，字符串外的格式缩进保持原样。
  String _sanitizeJsonControlChars(String json) {
    final buffer = StringBuffer();
    var inString = false;
    var i = 0;
    while (i < json.length) {
      final ch = json[i];
      if (!inString) {
        if (ch == '"') inString = true;
        buffer.write(ch);
        i++;
        continue;
      }
      // 字符串内部：保留已有转义序列（如 \" \\ \n），跳过被转义的字符
      if (ch == '\\') {
        buffer.write(ch);
        if (i + 1 < json.length) {
          buffer.write(json[i + 1]);
          i += 2;
        } else {
          i++;
        }
        continue;
      }
      if (ch == '"') {
        inString = false;
        buffer.write(ch);
        i++;
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (code >= 0x20) {
        buffer.write(ch);
        i++;
        continue;
      }
      // 裸控制字符 → 合法转义序列
      switch (ch) {
        case '\n':
          buffer.write(r'\n');
        case '\r':
          buffer.write(r'\r');
        case '\t':
          buffer.write(r'\t');
        default:
          buffer.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
      }
      i++;
    }
    return buffer.toString();
  }

  /// 从含中文推理文本中提取 JSON 子串。
  ///
  /// 推理模型（SenseNova/DeepSeek-R1）的 reasoning 字段混有中文思考文本和 JSON，
  /// 简单括号匹配会被中文文本中的 `{` `}` 干扰。本方法按优先级尝试：
  /// 1. 提取 ```json ... ``` 包裹的代码块
  /// 2. 提取普通的 ``` ... ``` 代码块
  /// 3. 按 JSON 结构标记（{"results":  / {"tags": / [{"id":）定位并做括号配对
  /// 4. 兜底：简单首 `{` 尾 `}` 匹配
  String? _extractJsonString(String text) {
    // 1. 优先尝试提取 ```json ... ``` 包裹的块
    final jsonBlockReg = RegExp(r'```json\s*([\s\S]*?)\s*```');
    var match = jsonBlockReg.firstMatch(text);
    if (match != null) {
      return match.group(1)!.trim();
    }

    // 2. 尝试提取普通的 ``` ... ``` 块
    final codeBlockReg = RegExp(r'```\s*([\s\S]*?)\s*```');
    match = codeBlockReg.firstMatch(text);
    if (match != null) {
      return match.group(1)!.trim();
    }

    // 3. 按 JSON 结构标记定位真正的 JSON 起始位置，做括号配对
    //    推理模型的 reasoning 中常有 `{"results":[{"id":...}]}` 这样的输出
    final candidate = _findJsonByStructureMarkers(text);
    if (candidate != null) return candidate;

    // 4. 兜底：简单首 { 尾 } 匹配
    final firstBrace = text.indexOf('{');
    final firstBracket = text.indexOf('[');
    final lastBrace = text.lastIndexOf('}');
    final lastBracket = text.lastIndexOf(']');

    int start = -1;
    int end = -1;

    if (firstBrace != -1 && firstBracket != -1) {
      if (firstBrace < firstBracket) {
        start = firstBrace;
        end = lastBrace;
      } else {
        start = firstBracket;
        end = lastBracket;
      }
    } else if (firstBrace != -1) {
      start = firstBrace;
      end = lastBrace;
    } else if (firstBracket != -1) {
      start = firstBracket;
      end = lastBracket;
    }

    if (start != -1 && end != -1 && end > start) {
      return text.substring(start, end + 1);
    }

    return null;
  }

  /// 通过 JSON 结构标记（如 `{"results":`、`[{"id":`）定位起始位置，
  /// 然后做括号配对提取完整 JSON 子串。
  ///
  /// 这能避免中文推理文本中 `type(select:...)` 等非 JSON 括号的干扰。
  String? _findJsonByStructureMarkers(String text) {
    // 常见的 JSON 输出开头模式
    final markerPatterns = [
      RegExp(r'\{"results"\s*:\s*\[', multiLine: true),
      RegExp(r'\{"tags"\s*:\s*\[', multiLine: true),
      RegExp(r'\{"message"\s*:', multiLine: true),
      RegExp(r'\[{"id"\s*:', multiLine: true),
    ];

    int? bestStart;
    for (final pattern in markerPatterns) {
      final m = pattern.firstMatch(text);
      if (m != null) {
        final pos = m.start;
        if (bestStart == null || pos < bestStart) {
          bestStart = pos;
        }
      }
    }

    if (bestStart == null) return null;

    // 从 bestStart 开始做括号配对
    final firstChar = text[bestStart];
    final openChar = firstChar;
    final closeChar = firstChar == '{' ? '}' : ']';

    int depth = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = bestStart; i < text.length; i++) {
      final ch = text[i];

      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == '\\') {
        escaped = true;
        continue;
      }
      if (ch == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;

      if (ch == openChar) {
        depth++;
      } else if (ch == closeChar) {
        depth--;
        if (depth == 0) {
          return text.substring(bestStart, i + 1);
        }
      }
    }

    // 配对失败（可能是截断的），尝试返回从头到尾的内容
    if (depth > 0 && text.length > bestStart + 1) {
      return text.substring(bestStart);
    }

    return null;
  }

  String _stripMarkdownCodeBlock(String content) {
    final trimmed = content.trim();
    final codeBlockRegex = RegExp(
      r'^```(?:json)?\s*\n?([\s\S]*?)\n?\s*```$',
      multiLine: false,
    );
    final match = codeBlockRegex.firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return trimmed;
  }

  dynamic _sanitizeRequestBodyForLogging(dynamic body) {
    // release 模式跳过深拷贝（含 base64 图片时尤其耗时），只记录占位符
    if (!kDebugMode) return '<release_mode_skipped>';
    try {
      if (body is String) {
        final decoded = jsonDecode(body);
        return _sanitizeMapOrList(decoded);
      }
      return _sanitizeMapOrList(body);
    } catch (_) {
      return body;
    }
  }

  dynamic _sanitizeMapOrList(dynamic val) {
    if (val is Map) {
      final newMap = <String, dynamic>{};
      for (final key in val.keys) {
        final kStr = key.toString();
        final value = val[key];
        if (kStr == 'data' && value is String && _isLikelyBase64Image(value)) {
          newMap[kStr] = '<IMAGE_DATA: ${_estimateImageSize(value)}>';
        } else if (kStr == 'image_url' &&
            value is Map &&
            value['url'] is String &&
            (value['url'] as String).startsWith('data:')) {
          final url = value['url'] as String;
          final mime = _extractMimeTypeFromDataUrl(url);
          newMap[kStr] = {'url': 'data:$mime;<BASE64_IMAGE_DATA>'};
        } else if (kStr == 'input_image' && value is Map) {
          newMap[kStr] = {
            'type': value['type'] ?? 'base64',
            'data': '<IMAGE_BASE64_DATA>',
          };
        } else if (kStr == 'inline_data' &&
            value is Map &&
            value['data'] is String &&
            _isLikelyBase64Image(value['data'])) {
          newMap[kStr] = {
            'mime_type': value['mime_type'] ?? 'image/...',
            'data': '<INLINE_IMAGE_DATA>',
          };
        } else {
          newMap[kStr] = _sanitizeMapOrList(value);
        }
      }
      return newMap;
    } else if (val is List) {
      return val.map((item) => _sanitizeMapOrList(item)).toList();
    } else if (val is String && _isLikelyBase64Image(val)) {
      return '<BASE64_IMAGE_STRING: ${_estimateImageSize(val)}>';
    }
    return val;
  }

  bool _isLikelyBase64Image(String str) {
    if (str.length < 500) return false;
    final trimmed = str.trim();
    if (trimmed.startsWith('data:image/')) return true;
    if (trimmed.startsWith('/') && trimmed.length > 1000) return true;
    if (trimmed.length > 2000 && RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed)) {
      return true;
    }
    if (trimmed.length > 5000 &&
        !trimmed.contains('\n') &&
        !trimmed.contains('\r') &&
        !trimmed.contains('\t')) {
      return true;
    }
    return false;
  }

  String _estimateImageSize(String base64) {
    try {
      final kb = (base64.length * 3 / 4 / 1024);
      if (kb >= 1024) {
        return '${(kb / 1024).toStringAsFixed(1)}MB';
      }
      return '${kb.toStringAsFixed(1)}KB';
    } catch (_) {
      return 'unknown';
    }
  }

  String _extractMimeTypeFromDataUrl(String dataUrl) {
    final match = RegExp(r'data:([^;]+)').firstMatch(dataUrl);
    return match?.group(1) ?? 'image/...';
  }

  String _formatJsonForLogging(dynamic data) {
    try {
      if (data is String) {
        final decoded = jsonDecode(data);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      }
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  /// 将小米运动健康日汇总 + 单次运动记录拼接为 AI 可读文本
  String _buildHealthDataText(
    HealthDailyMetrics? m,
    List<HealthSportRecord> sports,
  ) {
    if (m == null) {
      return '当日暂无小米运动健康数据';
    }

    final lines = <String>[];
    lines.add('- 日期: ${m.date}');
    lines.add('- 步数: ${m.steps} 步');
    lines.add('- 距离: ${(m.distanceMeters / 1000).toStringAsFixed(2)} km');
    lines.add('- 消耗: ${m.calories.toStringAsFixed(0)} kcal');
    lines.add('- 活跃分钟: ${m.activeMinutes} 分钟');
    if (m.standingCount > 0) {
      lines.add('- 站立次数: ${m.standingCount} 次');
    }

    if (m.sleepDurationMinutes > 0) {
      final sleepH = m.sleepDurationMinutes ~/ 60;
      final sleepM = m.sleepDurationMinutes % 60;
      final sleepScoreStr = m.sleepScore != null ? ' (得分: ${m.sleepScore})' : '';
      // 时长为当天各段之和（含午睡），入睡/醒来则是主睡眠段，两者口径需分别标注以免 AI 误判
      lines.add('- 全天睡眠时长: $sleepH小时$sleepM分$sleepScoreStr');
      lines.add('  - 深睡: ${m.deepSleepMinutes}分 | 浅睡: ${m.lightSleepMinutes}分 | REM: ${m.remSleepMinutes}分 | 清醒: ${m.awakeMinutes}分');
      final startHm = HealthDailyMetrics.sleepTimeToHHmm(m.sleepStartTime);
      final endHm = HealthDailyMetrics.sleepTimeToHHmm(m.sleepEndTime);
      if (startHm != null && endHm != null) {
        lines.add('  - 主睡眠入睡: $startHm | 醒来: $endHm');
      }
    }

    if (m.restingHeartRate != null && m.restingHeartRate! > 0) {
      lines.add('- 静息心率: ${m.restingHeartRate} bpm');
    }
    if (m.avgHeartRate != null && m.avgHeartRate! > 0) {
      lines.add('- 平均心率: ${m.avgHeartRate} bpm');
    }
    if (m.avgSpo2 != null && m.avgSpo2! > 0) {
      lines.add('- 平均血氧: ${m.avgSpo2}%');
    }
    if (m.avgStress != null && m.avgStress! > 0) {
      lines.add('- 平均压力: ${m.avgStress}');
    }

    if (sports.isNotEmpty) {
      lines.add('- 单次运动记录:');
      for (final s in sports) {
        final durMin = s.durationSeconds ~/ 60;
        lines.add('  - ${s.title} (${s.category}): $durMin分钟, ${(s.distanceMeters / 1000).toStringAsFixed(2)}km, ${s.calories}kcal${s.avgHeartRate != null ? ', 均心率${s.avgHeartRate}' : ''}');
      }
    }

    return lines.join('\n');
  }

  /// 将屏幕使用时间拼接为 AI 可读文本
  String _buildScreenDataText(TodayScreenUsage? usage) {
    if (usage == null) {
      return '当前设备不支持屏幕使用时间统计或未授权';
    }

    final lines = <String>[];
    lines.add('- 屏幕总时长: ${usage.formattedTotalTime} (${usage.totalMinutes}分钟)');
    lines.add('- ${usage.diffDescription}');

    final topApps = usage.appList.take(5).toList();
    if (topApps.isNotEmpty) {
      lines.add('- Top应用:');
      for (final app in topApps) {
        final name = app.appName.isEmpty ? app.packageName : app.appName;
        lines.add('  - $name: ${app.formattedDuration}');
      }
    }

    return lines.join('\n');
  }

  Future<DailyScore> analyzeDailyScore({
    required List<DiaryRecord> records,
    required DateTime date,
    String? userInfo,
    HealthDailyMetrics? healthMetrics,
    List<HealthSportRecord> sportRecords = const [],
    TodayScreenUsage? screenUsage,
  }) async {
    if (_config == null) throw Exception('AI config not set');

    if (records.length < 3) {
      throw ArgumentError('当日记录过少，暂无法评分');
    }

    final recordsStr = StringBuffer();
    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      recordsStr.writeln('记录 ${i + 1}:');
      recordsStr.writeln('- 时间: ${r.time.toIso8601String()}');
      if (r.displayTag.isNotEmpty) {
        recordsStr.writeln('- 分类: ${r.displayTag}');
      }
      if (r.tags.isNotEmpty) {
        recordsStr.writeln('- 标签: ${r.tags.join(', ')}');
      }
      if (r.content.isNotEmpty) {
        recordsStr.writeln('- 内容: ${r.content}');
      }
      if (r.bodyState != null && r.bodyState!.isNotEmpty) {
        recordsStr.writeln('- 身体状态: ${jsonEncode(r.bodyState)}');
      }
      recordsStr.writeln();
    }

    // 拼接小米运动健康客观数据
    final healthStr = _buildHealthDataText(healthMetrics, sportRecords);
    // 拼接屏幕使用时间数据
    final screenStr = _buildScreenDataText(screenUsage);

    final systemPrompt = defaultSystemPrompts['daily_score_system'] ?? '';
    final userPrompt = '请根据上述规则和以下数据进行评分与分析。\n\n[当日记录]\n${recordsStr.toString()}\n\n[健康数据]\n$healthStr\n\n[屏幕使用时间]\n$screenStr\n\n[用户信息]\n${userInfo ?? "无"}';

    dynamic requestBody;
    final String endpoint = _generateContentEndpoint;

    if (_config!.provider == 'gemini') {
      requestBody = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': userPrompt},
            ],
          },
        ],
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'generationConfig': {
          'temperature': _temperature,
          'maxOutputTokens': _maxTokens,
          'responseMimeType': 'application/json',
        },
      };
    } else {
      final isOmni = _config!.modelName.toLowerCase().contains('omni');
      final formattedMessages = [
        if (isOmni) ...[
          {
            'role': 'system',
            'content': [
              {'type': 'text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userPrompt},
            ],
          },
        ] else ...[
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      ];

      final bodyMap = _buildBaseBody(
        messages: formattedMessages,
        responseFormat: {'type': 'json_object'},
      );

      if (isOmni) {
        bodyMap['sessionId'] = DateTime.now().millisecondsSinceEpoch.toString();
        bodyMap['output_modalities'] = ['text'];
      }

      requestBody = bodyMap;
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      'AI评分分析请求 [${_config!.provider}] [${_config!.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    final response = await _postWithKeyRotation<dynamic>(
      endpoint,
      data: requestBody,
      scene: 'AI评分分析',
    );
    final responseContent = _extractTextFromResponse(response.data);
    LoggerService.instance.logAI(
      'AI评分分析响应:\n${_formatJsonForLogging(response.data)}',
    );

    final jsonResult = _parseJsonFromAiContent(responseContent) as Map<String, dynamic>;

    final canScore = jsonResult['canScore'] ?? true;
    if (!canScore) {
      throw Exception('AI判定当日信息过少，暂无法评分');
    }

    // 钳位：模型偶尔会返回超界分值，未钳位的分会把统计页的分数环画爆
    final totalScore = clampScore((jsonResult['totalScore'] as num?)?.toInt() ?? 60);
    final rawDimensionScores = jsonResult['dimensionScores'] as Map? ?? {};
    final dimensionScores = rawDimensionScores.map(
      (k, v) => MapEntry(k.toString(), clampScore((v as num?)?.toInt() ?? 60)),
    );

    return DailyScore(
      id: const Uuid().v4(),
      date: date,
      totalScore: totalScore,
      dimensionScores: dimensionScores,
      summary: jsonResult['summary']?.toString() ?? '',
      suggestions: jsonResult['suggestions']?.toString() ?? '',
      recordCount: records.length,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Future<bool> checkImageRecognition(AiConfig config, String imageBase64) async {
    updateConfig(config, temperature: 0.1, maxTokens: 50);

    dynamic requestBody;
    String endpoint = _generateContentEndpoint;

    if (config.provider == 'gemini') {
      requestBody = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': '请问这张图片里写了什么数字？直接回答数字即可，不要有其他解释。'},
              {
                'inline_data': {'mime_type': 'image/png', 'data': imageBase64},
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.1,
          'maxOutputTokens': 200,
        },
      };
      endpoint = 'v1beta/models/${config.modelName}:generateContent';
    } else {
      final isOmni = config.modelName.toLowerCase().contains('omni');
      List<dynamic> contentList;
      if (isOmni) {
        contentList = [
          {'type': 'text', 'text': '请问这张图片里写了数字多少？直接回答数字即可，不要有其他解释。'},
          {
            'type': 'input_image',
            'input_image': {
              'type': 'base64',
              'data': [imageBase64],
            },
          },
        ];
      } else {
        contentList = [
          {'type': 'text', 'text': '请问这张图片里写了数字多少？直接回答数字即可，不要有其他解释。'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$imageBase64'},
          },
        ];
      }

      requestBody = _buildBaseBody(
        messages: [
          {
            'role': 'user',
            'content': contentList,
          },
        ],
      );
      requestBody['temperature'] = 0.1;
      requestBody['max_tokens'] = 200;
    }

    final sanitizedBody = _sanitizeRequestBodyForLogging(requestBody);
    LoggerService.instance.logAI(
      '图片识别测试请求 [${config.provider}] [${config.modelName}] $endpoint:\n${_formatJsonForLogging(sanitizedBody)}',
    );

    final response = await _postWithKeyRotation<dynamic>(
      endpoint,
      data: requestBody,
      scene: '图片识别测试',
    );
    final data = response.data;
    LoggerService.instance.logAI('图片识别测试响应:\n${_formatJsonForLogging(data)}');

    final String result = _extractTextFromResponse(data);
    LoggerService.instance.logAI('大模型图片识别测试结果: $result');

    final cleanResult = result.trim().replaceAll(' ', '');
    return cleanResult.contains('11') || cleanResult.contains('十一');
  }
}

/// 一次发信的观测上下文：本次真正用的 Key、起算时刻、以及流式首字时刻
///
/// 之所以要把这三样捆在一起透传，而不是各站点各自记：`AiService` 是单例，
/// 主聊天、悬浮小Q、日记提取、每日评分并发用它，任何「上次取到的 Key」这种
/// 实例字段都会串台（历史上 Dio 全局 header 串台就是同一类问题）。
/// 观测行必须归因到**真正发出这个请求的那把 Key**，所以只能随请求走。
/// 一次发信的上下文：本次真正用的 Key、本次携带的密钥池快照、起算时刻
///
/// 之所以要把这些捆在一起透传，而不是各站点各自读实例字段：`AiService` 是
/// 单例，主聊天、悬浮小Q、日记提取、每日评分并发用它，任何「上次取到的 Key」
/// 这种实例字段都会串台（历史上 Dio 全局 header 串台就是同一类问题）。
/// 冷却记账必须归因到**真正发出这个请求的那把 Key**，所以只能随请求走。
class _SendTrace {
  /// 发信场景，用于日志定位（`对话请求`、`带工具流式对话` 等）
  final String scene;

  /// 本次真正使用的 Key（单 Key 厂商 / 锁定 Key 时为 null，走全局 header）
  final String? sentKey;

  /// 本次请求携带的厂商密钥池快照（单 Key / 无池时为空）
  final List<String> poolKeys;

  /// 起表时刻（不含取 Key 与整池排队等待）
  final DateTime startedAt;

  _SendTrace({
    required this.scene,
    required this.sentKey,
    this.poolKeys = const [],
    required this.startedAt,
  });
}
