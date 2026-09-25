import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:dio/dio.dart';
import 'package:qnote_flutter/models/ai_request_stat.dart';

/// 商汤免费网关的限流形态。
///
/// 判定错误的处置方式必须按形态分流，因为网关其实有**两层**互不相干的限流：
/// [QuotaSignal.rpsBurst] 是「发太快」，[QuotaSignal.tpm] 是「额度用完」，
/// 把前者当后者处理会把一把完全健康的 Key 白关一分钟。
enum QuotaSignal {
  /// 不是限流（正常响应、业务参数错误等）
  none,

  /// `{"code":"8","message":"rps exhausted"}` —— 同一把 Key 亚秒级连发即触发
  rpsBurst,

  /// `RateLimitExceeded.EndpointTPMExceeded` —— token 额度（tpm/rpm）耗尽
  tpm,

  /// 401/403 —— 该 Key 失效、被禁用或无该模型权限
  auth,

  /// 5xx —— 网关侧故障，与 Key 无关，不应归因冷却
  server,
}

/// 一条「报文 → 属于哪种限流形态」的声明规则（借 CPA 的 request-scoped-errors 思路）
///
/// 把判据从 if 链变成**有序表**有两个实际收益：一是命中顺序即优先级，
/// 「rps 必须排在 TPM 之前」这条约束写在表里而不是散落在注释里；二是云端
/// [SensenovaQuotaPolicy.apply] 可以整表替换 —— 服务商改了报错措辞时
/// 不必发版，只需要换 JSON 里的一段规则。
class QuotaRule {
  /// 响应体（已转小写）命中任一子串即算正文匹配；空列表表示不看正文
  final List<String> bodyAny;

  /// HTTP 状态码命中其一即算状态匹配；空列表表示不看状态码
  final List<int> statusAny;

  /// 状态码下界（含），用于「5xx 一律算网关故障」这类区间判据；null 表示不启用
  final int? statusFrom;

  /// 命中后归一的限流形态
  final QuotaSignal signal;

  /// 该规则专属的 Key 冷却时长；null 表示沿用 [SensenovaQuotaPolicy.keyCooldown] 的形态默认值
  final Duration? cooldownOverride;

  const QuotaRule({
    this.bodyAny = const [],
    this.statusAny = const [],
    this.statusFrom,
    required this.signal,
    this.cooldownOverride,
  });

  /// 规则是否命中
  ///
  /// 正文与状态码两类条件**都给出时必须同时满足**：否则网关 500 的正文里
  /// 出现 "rate limit" 字样就会被配额规则抢走，把该等分钟级回填的故障
  /// 误判成换 Key 能解决的问题。只给一类条件时按该类判。
  bool matches({int? statusCode, String body = ''}) {
    final hasBodyCond = bodyAny.isNotEmpty;
    final hasStatusCond = statusAny.isNotEmpty || statusFrom != null;
    if (hasBodyCond && !bodyAny.any(body.contains)) return false;
    if (hasStatusCond) {
      if (statusCode == null) return false;
      final statusHit =
          statusAny.contains(statusCode) ||
          (statusFrom != null && statusCode >= statusFrom!);
      if (!statusHit) return false;
    }
    // 两类条件都没给等于「无条件命中」，会让后面的规则全部失效，必须视为不匹配
    return hasBodyCond || hasStatusCond;
  }
}

/// [SensenovaQuotaPolicy.verdict] 的结果：形态 + 该给 Key 关多久
///
/// 冷却时长之所以和形态一起返回，是因为声明规则可以自带 override（例如云端把
/// 「模型未开通」这条 403 规则配成 1 小时），只回 [QuotaSignal] 会丢掉这个信息。
class QuotaVerdict {
  final QuotaSignal signal;
  final Duration keyCooldown;

  /// 命中该判据的规则（null 表示走的是兜底分类，不是表里的规则）
  final QuotaRule? rule;

  const QuotaVerdict({
    required this.signal,
    required this.keyCooldown,
    this.rule,
  });

  const QuotaVerdict.none()
    : signal = QuotaSignal.none,
      keyCooldown = Duration.zero,
      rule = null;
}

/// 商汤网关（`https://token.sensenova.cn/v1`）限流与换 Key 节奏的策略层
///
/// 本类刻意做成**不依赖 Dio 实例、不依赖 Key 池、不发网络请求**的纯函数集合，
/// 让「限流怎么分类、一把 Key 该关多久、下一次什么时候发」这些决策可以单测覆盖
/// （`test/core/ai/sensenova_quota_policy_test.dart`）。
///
/// 下列所有取值以 2026-09-25 用内置 Key 直连实测为依据（`curl --noproxy '*'`，
/// 响应头里没有 `Retry-After` 与 `x-ratelimit-*`，判据只能从 body 拿）：
///
/// 1. 两层限流的原话分别是 `inference exceeds tpm/rpm limit`
///    （`RateLimitExceeded.EndpointTPMExceeded`）与 `rps exhausted`（`code: 8`）；
///    同一把 Key 在 0.6 秒内连发后，第 2~5 次全部返回 `rps exhausted`。
/// 2. 额度看起来是**整池共享、按分钟回填**：静置 8 分钟后单发 40-token 小请求仍只有
///    3/9 把能过；9 把不同 Key 在 1 秒内并发各发 1 次则 0/9 全拒 TPM；两把 Key
///    在 +121s / +122s 同一秒恢复。所以换 Key 换不来新配额，但能把负载均摊到每把 Key，
///    避免单 Key 被 TPM 与 rps 两层同时打死（历史行为：一次提问 3+ 轮全砸一把 Key，
///    一次 429 又亚秒连扫 9 把，把整池标成冷却，于是下一条消息第一次 429 就整条失败）。
///
/// **阈值不是写死的**：除 [perRequestKeyRotation] 之外的字段都是可变静态量，
/// 由云端 `api-endpoint.json` 的 `quota_policy` 对象经 [apply] 覆盖（见
/// `FreeModelService.fetchDynamicCpaEndpoint`）。之所以走这条路而不是本地配置：
/// 上面这些数值会随服务商策略漂移（配额窗口从 1 分钟改成 5 分钟、报错措辞换词），
/// 每漂移一次就发一版是不可接受的；而 [apply] 对每个字段都做区间钳制、脏值一律
/// 忽略，云端 JSON 被污染时也只会退回内置默认值。
class SensenovaQuotaPolicy {
  SensenovaQuotaPolicy._();

  /// 逐请求现取 Key 的总开关（应急回退用）
  ///
  /// 置 false 时 `AiService._beforeSend` 直接返回 null，回到「整条消息粘着一把 Key、
  /// 只有失败才换」的旧行为。真机若发现商汤按 Key 做前缀缓存导致首包明显变慢，
  /// 改这一行 + 热重载即可，不需要重新构建；也可以通过云端 `quota_policy`
  /// 的 `per_request_key_rotation` 远程关掉（老版本 App 不认这个字段，所以要回退
  /// 时得先确认线上版本已支持 [apply]）。
  static bool perRequestKeyRotation = _defaultPerRequestKeyRotation;
  static const bool _defaultPerRequestKeyRotation = true;

  /// 是否在流式请求体里带 `stream_options: {include_usage: true}`
  ///
  /// 默认 **false**：该参数在商汤网关上未实测，而未知参数导致的 400 是**确定性错误**
  /// （重试也救不回来，会把每一次对话都打死），风险远大于「多拿到几个 token 数」。
  /// 观测面板对 token 字段的依赖是软的（缺值显示为「未上报」）。确认网关接受后
  /// 由云端置 true，届时每把 Key 的实际消耗量才会进表。
  static bool sendStreamUsage = _defaultSendStreamUsage;
  static const bool _defaultSendStreamUsage = false;

  /// 单次请求内的总发信次数（含首发，即最多换这么几把 Key）
  ///
  /// 旧值是池容量 9，其职责是「一次失败后扫完整池找一把有额度的」。改造后每次请求
  /// 本身就在换 Key（游标无论如何都在推进），深度不再承担「扫池」职责，只需承担
  /// 「穿越偶发抖动」；而实测亚秒级扫全池 0/9 成功，多扫只是把失败反馈推迟到
  /// 移动端用户无法接受的程度。
  static int poolMaxAttempts = _defaultPoolMaxAttempts;
  static const int _defaultPoolMaxAttempts = 4;

  /// 全池两次「真正发出请求」之间的最小间隔
  ///
  /// 直接对着 rps 层设的护栏：多个消费者（主聊天 / 悬浮小Q / 日记提取 / 每日评分 /
  /// 生图）共用一个进程内的池，没有这道闸就会在同一次事件循环里把请求叠出去。
  static Duration minSendInterval = _defaultMinSendInterval;
  static const Duration _defaultMinSendInterval = Duration(milliseconds: 250);

  /// 整池都在冷却时，最多排队等多久
  ///
  /// 替代原先的「整池冷却即放弃」熔断：额度按分钟滚动回填，等比换 Key 有用；
  /// 但也不能无界地等，45 秒是「用户还愿意等」与「一分钟窗口必然已经回填」的折中。
  static Duration maxQuotaHold = _defaultMaxQuotaHold;
  static const Duration _defaultMaxQuotaHold = Duration(seconds: 45);

  /// 免费网关单次响应的 token 上限
  ///
  /// App 里 assistant 角色的 `maxTokens` 被 [AiTemperatures] 强制抬到 ≥32000（为长文
  /// 分析防截断），但网关 TPM 按 token 计，32000 的预留对免费池是纯浪费。16000 是
  /// 「腰斩预留、又不伤推理模型思维链」的折中；若诊断面板里
  /// `AI响应被截断 (finish_reason: length)` 变多，直接下发 `free_gateway_max_tokens`
  /// 上调即可，不需要发版。
  static int freeGatewayMaxTokens = _defaultFreeGatewayMaxTokens;
  static const int _defaultFreeGatewayMaxTokens = 16000;

  /// rps 类故障的 Key 冷却：只需跨过秒级窗口
  static Duration rpsCooldown = _defaultRpsCooldown;
  static const Duration _defaultRpsCooldown = Duration(seconds: 2);

  /// TPM 类故障的 Key 冷却：对齐按分钟滚动的回填周期
  static Duration tpmCooldown = _defaultTpmCooldown;
  static const Duration _defaultTpmCooldown = Duration(seconds: 60);

  /// 401/403 类故障的 Key 冷却
  ///
  /// 与 TPM 同长度只是当前实测下的取值（内置 Key 没有真失效过，无法区分
  /// 「暂时不可用」与「永久报废」）。若诊断面板看到某把 Key 反复只出 auth，
  /// 下发一个更大的值就能把它长期摘出轮换，而不必等它随机撞上来。
  static Duration authCooldown = _defaultAuthCooldown;
  static const Duration _defaultAuthCooldown = Duration(seconds: 60);

  /// 换 Key 重试之间的等待基数（毫秒）
  ///
  /// 抖动窗口跟着形态写死在 [rotationDelay] 里（rps +300ms、TPM +200ms、
  /// 鉴权 +60ms、server +150ms），只有基数可下发：基数对着实测窗口设
  /// （rps 突发 0.6s、TPM 分钟级回填），改它等于改对故障周期的判断，
  /// 属于「拿到诊断面板数据之后」才做的事。
  static int rpsRetryWaitMs = _defaultRpsRetryWaitMs;
  static int tpmRetryWaitMs = _defaultTpmRetryWaitMs;
  static int authRetryWaitMs = _defaultAuthRetryWaitMs;
  static int serverRetryBaseMs = _defaultServerRetryBaseMs;
  static const int _defaultRpsRetryWaitMs = 350;
  static const int _defaultTpmRetryWaitMs = 150;
  static const int _defaultAuthRetryWaitMs = 60;
  static const int _defaultServerRetryBaseMs = 300;

  // ── 错误分类规则表 ──────────────────────────────────────────────

  /// 内置默认规则（顺序即优先级，见 [QuotaRule.matches] 的与条件说明）
  static const List<QuotaRule> _builtinRules = [
    // 5xx 排在所有正文判据之前：网关故障时响应体里完全可能带着 "rate limit" 之类的
    // 上游原文，若先按措辞判定就会把一次网关抖动算成「这把 Key 额度用完」，白关一分钟。
    // 它也不受「带内错误没有状态码」影响 —— statusFrom 规则要求 statusCode 非空，
    // 所以 SSE 帧里的 error 对象仍由后面的措辞规则接管。
    QuotaRule(statusFrom: 500, signal: QuotaSignal.server),
    // `code: 8` 同时覆盖 rps 与 rpm 两种报错，但它是**分钟窗口**的额度，
    // 处置该跟 TPM 同类（换 Key + 按分钟冷却、并允许整池排队）而不是秒级突发；
    // 旧实现把它一起归到 rpsBurst，于是只关 2 秒就复用，同一分钟里必然再撞一次。
    // 因此这条必须排在 rps 之前（rps 规则的 `"code":8` 会把它也吃掉）。
    QuotaRule(bodyAny: ['rpm exhausted'], signal: QuotaSignal.tpm),
    // rps 放在 TPM 之前：它俩都是 429，处置却完全相反（一个等 2 秒就复用，
    // 一个必须换 Key 并等一分钟），先具体后泛化才不会把快故障误判成慢故障。
    QuotaRule(
      bodyAny: [
        'rps exhausted',
        '"code":8',
        '"code": 8',
      ],
      signal: QuotaSignal.rpsBurst,
    ),
    // 措辞表刻意只做子串匹配、不做数字匹配（历史踩坑：把正文里出现的 401/429
    // 数字当成状态码判过限流），只认明确表达「额度/配额/并发超限」的词。
    QuotaRule(
      bodyAny: [
        'endpointtpmexceeded',
        'ratelimitexceeded',
        'too many requests',
        'rate limit',
        'rate_limit',
        'tpm',
        'rpm',
        'quota',
        'insufficient',
        '配额',
        '超限',
        '并发',
      ],
      signal: QuotaSignal.tpm,
    ),
    QuotaRule(statusAny: [401, 403], signal: QuotaSignal.auth),
    // 429 但没读到 body（流式响应体已被消费、或超时）：保守按分钟额度处理
    QuotaRule(statusAny: [429], signal: QuotaSignal.tpm),
  ];

  /// 当前生效的规则表（[apply] 可整表替换）
  static List<QuotaRule> _rules = _builtinRules;

  /// 把 HTTP 状态码 + 响应体文本归一成 [QuotaSignal]
  ///
  /// [statusCode] 为 null 表示「带内错误」（HTTP 200，但 SSE 帧里塞了 error 对象），
  /// 此时只按 [bodyText] 判。反过来 HTTP 2xx 配上一段含 tpm 字样的正文**不算**限流 ——
  /// 模型完全可能把服务商的报错文本原样复述给用户，判成限流会引发无意义的重试风暴。
  static QuotaSignal classify({int? statusCode, String? bodyText}) {
    return verdict(statusCode: statusCode, bodyText: bodyText).signal;
  }

  /// [classify] 的完整版：同时给出该形态对应的 Key 冷却时长
  static QuotaVerdict verdict({int? statusCode, String? bodyText}) {
    if (statusCode != null && statusCode >= 200 && statusCode < 400) {
      return const QuotaVerdict.none();
    }
    final body = (bodyText ?? '').toLowerCase();
    for (final rule in _rules) {
      if (rule.matches(statusCode: statusCode, body: body)) {
        return QuotaVerdict(
          signal: rule.signal,
          keyCooldown: rule.cooldownOverride ?? keyCooldown(rule.signal),
          rule: rule,
        );
      }
    }
    return const QuotaVerdict.none();
  }

  /// 该形态下应该把「本次真正发出去的那把 Key」置入冷却多久
  ///
  /// 返回 [Duration.zero] 表示不该归因到 Key（网关故障、业务参数错等，
  /// 换 Key 也不会变好，给 Key 打冷却只会让池子凭空变小）。
  static Duration keyCooldown(QuotaSignal signal) {
    switch (signal) {
      case QuotaSignal.rpsBurst:
        return rpsCooldown;
      case QuotaSignal.tpm:
        return tpmCooldown;
      case QuotaSignal.auth:
        // 失效 Key 必须冷却：逐请求轮换之后，不打冷却的坏 Key 会每 9 个请求
        // 又被端上来一次，把用户可见的失败率固定抬上去。
        return authCooldown;
      case QuotaSignal.server:
      case QuotaSignal.none:
        return Duration.zero;
    }
  }

  // ── 远端下发入口 ──────────────────────────────────────────────

  /// 用云端 `quota_policy` 对象覆盖策略（缺字段/脏字段一律忽略）
  ///
  /// 调用方是 `FreeModelService`（拉到 `api-endpoint.json` 时与启动读缓存时各一次），
  /// 因此本函数可能在任意时刻被调用 —— 所有读取点都是**调用时取值**
  /// （`ai_service.dart` 里的 `SensenovaQuotaPolicy.poolMaxAttempts` 等），
  /// 所以下发生效后下一条请求就按新值走，不需要重建 AiService。
  ///
  /// 每个数值都钳制到「就算被写坏也不至于把 App 弄挂」的区间：深度上限压到池容量级别，
  /// 冷却与排队给分钟级上限，`max_tokens` 不低于一次工具往返所需。
  static void apply(Map<String, dynamic>? policy) {
    if (policy == null || policy.isEmpty) return;

    final attempts = _readInt(policy['pool_max_attempts']);
    if (attempts != null) poolMaxAttempts = attempts.clamp(1, 9);

    final throttle = _readInt(policy['min_send_interval_ms']);
    if (throttle != null) {
      minSendInterval = Duration(milliseconds: throttle.clamp(0, 3000));
    }

    final hold = _readInt(policy['max_quota_hold_seconds']);
    if (hold != null) maxQuotaHold = Duration(seconds: hold.clamp(0, 180));

    final maxTokens = _readInt(policy['free_gateway_max_tokens']);
    if (maxTokens != null) freeGatewayMaxTokens = maxTokens.clamp(1024, 64000);

    final rps = _readInt(policy['rps_cooldown_seconds']);
    if (rps != null) rpsCooldown = Duration(seconds: rps.clamp(0, 60));

    final tpm = _readInt(policy['tpm_cooldown_seconds']);
    if (tpm != null) tpmCooldown = Duration(seconds: tpm.clamp(1, 600));

    final auth = _readInt(policy['auth_cooldown_seconds']);
    if (auth != null) authCooldown = Duration(seconds: auth.clamp(1, 3600));

    final rotation = policy['per_request_key_rotation'];
    if (rotation is bool) perRequestKeyRotation = rotation;

    final usage = policy['send_stream_usage'];
    if (usage is bool) sendStreamUsage = usage;

    final rpsWait = _readInt(policy['rps_retry_wait_ms']);
    if (rpsWait != null) rpsRetryWaitMs = rpsWait.clamp(0, 3000);
    final tpmWait = _readInt(policy['tpm_retry_wait_ms']);
    if (tpmWait != null) tpmRetryWaitMs = tpmWait.clamp(0, 3000);
    final authWait = _readInt(policy['auth_retry_wait_ms']);
    if (authWait != null) authRetryWaitMs = authWait.clamp(0, 3000);
    final serverWait = _readInt(policy['server_retry_base_ms']);
    if (serverWait != null) serverRetryBaseMs = serverWait.clamp(0, 5000);

    final rules = _parseRules(policy['error_rules']);
    if (rules != null) _rules = rules;
  }

  /// 解析远端规则表；非法或为空时返回 null（表示保持内置规则）
  static List<QuotaRule>? _parseRules(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final parsed = <QuotaRule>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final signal = _parseSignal(map['signal']);
      if (signal == null) continue;
      final bodyAny = (map['contains'] is List)
          ? (map['contains'] as List).map((e) => e.toString().toLowerCase()).toList()
          : const <String>[];
      final statusAny = (map['status'] is List)
          ? (map['status'] as List)
                .map((e) => e is int ? e : int.tryParse(e.toString()))
                .whereType<int>()
                .toList()
          : const <int>[];
      final statusFrom = _readInt(map['status_from']);
      final cooldownSeconds = _readInt(map['cooldown_seconds']);
      if (bodyAny.isEmpty && statusAny.isEmpty && statusFrom == null) continue;
      parsed.add(
        QuotaRule(
          bodyAny: bodyAny,
          statusAny: statusAny,
          statusFrom: statusFrom,
          signal: signal,
          cooldownOverride: cooldownSeconds == null
              ? null
              : Duration(seconds: cooldownSeconds.clamp(0, 3600)),
        ),
      );
    }
    return parsed.isEmpty ? null : parsed;
  }

  static QuotaSignal? _parseSignal(dynamic raw) {
    switch (raw?.toString().trim().toLowerCase()) {
      case 'rps':
      case 'rpsburst':
      case 'rps_burst':
        return QuotaSignal.rpsBurst;
      case 'tpm':
      case 'quota':
        return QuotaSignal.tpm;
      case 'auth':
        return QuotaSignal.auth;
      case 'server':
        return QuotaSignal.server;
      default:
        return null;
    }
  }

  static int? _readInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  /// 恢复全部内置默认值（仅测试用）
  ///
  /// [apply] 是进程级可变状态，单测里一条用例下发的值会泄漏到下一条，
  /// 所以每个用例 setUp 都要显式重置一次。
  @visibleForTesting
  static void resetToDefaults() {
    perRequestKeyRotation = _defaultPerRequestKeyRotation;
    sendStreamUsage = _defaultSendStreamUsage;
    poolMaxAttempts = _defaultPoolMaxAttempts;
    minSendInterval = _defaultMinSendInterval;
    maxQuotaHold = _defaultMaxQuotaHold;
    freeGatewayMaxTokens = _defaultFreeGatewayMaxTokens;
    rpsCooldown = _defaultRpsCooldown;
    tpmCooldown = _defaultTpmCooldown;
    authCooldown = _defaultAuthCooldown;
    rpsRetryWaitMs = _defaultRpsRetryWaitMs;
    tpmRetryWaitMs = _defaultTpmRetryWaitMs;
    authRetryWaitMs = _defaultAuthRetryWaitMs;
    serverRetryBaseMs = _defaultServerRetryBaseMs;
    _rules = _builtinRules;
  }

  /// 当前生效的规则条数（仅测试用：断言下发是否真的替换了规则表）
  @visibleForTesting
  static int get activeRuleCount => _rules.length;

  /// 当前生效的内置默认规则（仅测试用）
  @visibleForTesting
  static List<QuotaRule> get builtinRules => _builtinRules;

  /// 换下一把 Key（或同把重发）之前的等待
  ///
  /// [attempt] 为本次请求内已失败的次数（从 1 开始），只有 [QuotaSignal.server]
  /// 用它做指数增长；配额类不随次数放大，因为再大的退避也超不过一分钟的回填窗口，
  /// 白等不如快点换下一把。
  static Duration rotationDelay(QuotaSignal signal, int attempt) {
    final rnd = Random();
    switch (signal) {
      case QuotaSignal.rpsBurst:
        // 下界必须跨过实测的 0.6 秒突发窗口，否则重发只是再撞一次 rps
        return Duration(milliseconds: rpsRetryWaitMs + rnd.nextInt(300));
      case QuotaSignal.tpm:
        return Duration(milliseconds: tpmRetryWaitMs + rnd.nextInt(200));
      case QuotaSignal.auth:
        return Duration(milliseconds: authRetryWaitMs + rnd.nextInt(60));
      case QuotaSignal.server:
        final baseMs = serverRetryBaseMs * (1 << (attempt - 1).clamp(0, 3));
        return Duration(milliseconds: baseMs + rnd.nextInt(150));
      case QuotaSignal.none:
        return Duration.zero;
    }
  }

  /// 是否属于「值得换一把 Key 再试」的形态
  static bool isKeyRotable(QuotaSignal signal) => signal != QuotaSignal.none;

  /// 归一形态 → 观测表 `outcome` 列的取值
  ///
  /// 放在策略层而不是各调用点各写一份：聊天链路与生图链路共用同一张
  /// `ai_request_stats`，口径必须一致，否则诊断卡里「同一件事有两种名字」就没法聚合。
  static String outcomeOf(QuotaSignal signal) {
    switch (signal) {
      case QuotaSignal.rpsBurst:
        return AiRequestOutcomes.rps;
      case QuotaSignal.tpm:
        return AiRequestOutcomes.tpm;
      case QuotaSignal.auth:
        return AiRequestOutcomes.auth;
      case QuotaSignal.server:
        return AiRequestOutcomes.server;
      case QuotaSignal.none:
        return AiRequestOutcomes.other;
    }
  }

  /// 消费错误响应体，供 [classify] 拿到判据文本
  ///
  /// 流式请求（`ResponseType.stream`）失败时 `error.response.data` 是一个**尚未被消费**的
  /// [ResponseBody]：Dio 在 `receiveDataWhenStatusError`（默认 true）下不会关闭非 2xx 的
  /// 响应流，事件还在这个单订阅流的缓冲里，所以事后仍能读一次。要点：
  ///
  /// 1. 单订阅 —— 同一异常第二次读必然失败，这里一律吞成 null；
  /// 2. 只给 [budget] 的时间窗，读不到就降级为「只看状态码」，绝不让分类阻断重试；
  /// 3. 最多取 [_maxErrorChunks] 个分片（`take` 满数后自行取消订阅、释放连接），
  ///    再按 [maxChars] 截断 —— 429 的 body 只有几百字节，一次就到；
  /// 4. HTTP 2xx 直接返回 null —— 成功响应的流要留给业务正文，不能碰。
  static Future<String?> readErrorBody(
    DioException error, {
    int maxChars = 512,
    Duration budget = const Duration(milliseconds: 800),
  }) async {
    final response = error.response;
    final statusCode = response?.statusCode;
    if (response == null || statusCode == null || statusCode < 400) {
      return null;
    }
    final data = response.data;
    if (data == null) {
      return null;
    }
    if (data is! ResponseBody) {
      // 非流式路径：data 已经是 String / Map，直接文本化
      return data.toString();
    }
    try {
      // 刻意不用 `await for`：单订阅流被二次 listen 时 StateError 是**同步**从
      // `moveNext()` 里抛的，经 `.timeout()` 的转换层会逃逸成 zone 未捕获异常
      // （写测试时实测炸出 `Bad state: Stream has already been listened to.`）。
      // `toList()` 把它收敛成 Future 的错误，超时也一样是 Future 层的
      // [TimeoutException]，两类失败都能被下面的 catch 吃掉。
      final chunks = await data.stream.take(_maxErrorChunks).toList().timeout(budget);
      if (chunks.isEmpty) {
        return null;
      }
      final text = utf8.decode(
        chunks.expand((chunk) => chunk).toList(),
        allowMalformed: true,
      );
      if (text.isEmpty) {
        return null;
      }
      return text.length > maxChars ? text.substring(0, maxChars) : text;
    } catch (_) {
      // 已被消费 / 超时 / 连接已断：分类降级，不影响重试决策继续按状态码走
      return null;
    }
  }

  /// 错误体最多读几个分片（429 响应通常一个 chunk 就完整）
  static const int _maxErrorChunks = 8;
}
