import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, protected, visibleForTesting;

import 'package:qnote_flutter/core/ai/account_auth_service_base.dart';
import 'package:qnote_flutter/core/ai/account_auth_types.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/account_checkin_result.dart';
import 'package:qnote_flutter/models/account_quota.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

export 'package:qnote_flutter/core/ai/account_auth_types.dart';

/// AutoClaw（智谱，国内版）订阅账号的登录、刷新、额度与签到
///
/// 接口与请求头来自 magpie 社区插件 `@magpie-community/opencode-autoclaw-auth`：
/// - 登录：手机验证码 `POST /userapi/v1/agent-send-code` →
///   `POST /userapi/v1/agent-login`（不能带尾斜杠，服务端会 307 到无斜杠地址，
///   而 dart:io 只为 GET/HEAD 自动跟随重定向，POST 会拿到空 body）；
/// - 刷新：`POST /userapi/v1/refresh`，旧版账号回落到 `agent-refresh`；
/// - 聊天：`POST {managedHost}/autoclaw-proxy/proxy/autoclaw/chat/completions`，
///   鉴权头是 `X-Authorization`，且请求体必须带官方 system prompt 前缀；
/// - 额度：`GET /agent-assetmgr/api/v2/wallets?biz_app_id=autoclaw`；
/// - 签到：`POST /autoclaw-proxy/proxy/autoclaw-task-complete`（`daily_signin`）。
///
/// 与发信层的契约和 `RaccoonAuthService` 一致：token 不落 `api_keys`、不参与
/// WebDAV 同步与备份导出；多账号选号复用同一个 [RaccoonAccountRouter]。
class AutoClawAuthService extends AccountAuthServiceBase {
  AutoClawAuthService._();

  static final AutoClawAuthService instance = AutoClawAuthService._();

  /// 厂商模板 id（`lib/config/models.dart` 与 `ai_providers.vendor_id`）
  static const String templateId = 'autoclaw-cn';

  /// 普通业务接口（登录/刷新/额度/签到）的 host
  static const String host = 'https://autoglm-api.zhipuai.cn';

  /// 对话网关 host（国内积分制通道）
  static const String managedHost = 'https://autoglm-acceleration-api.zhipuai.cn';

  /// 对话基址：与厂商模板的 defaultBaseUrl 保持一致
  static const String chatBase =
      '$managedHost/autoclaw-proxy/proxy/autoclaw';

  static const String product = 'autoclaw';
  static const String appId = '100003';
  static const String appKey = '38d2391985e2369a5fb8227d8e6cd5e5';

  /// 业务接口的客户端指纹（登录/刷新/额度/签到）
  static const String bizVersion = '1.18.1';
  static const String bizChannel = 'AutoClaw4';

  /// 国内对话网关的客户端指纹（2.1.0 积分制通道）
  static const String cnVersion = '2.1.0';
  static const String cnChannel = 'AutoClaw26';

  /// 网关会拒绝不带这行的请求；前缀在已有 system 消息里追加，避免出现
  /// 两个互相竞争的 system 角色。
  static const String officialSystemPrompt =
      'You are AutoClaw. Answer the user directly and concisely.';

  /// 提前多久刷新（与插件一致的 60 秒量级）
  static const Duration refreshMargin = Duration(seconds: 60);

  /// access token 的 JWT exp 前 10 分钟就视为过期：refresh token 一次一换，
  /// 拿临期 token 发信失败后再刷新，等于多烧一次轮换。
  static const Duration expirySkew = Duration(minutes: 10);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {'Accept': 'application/json'},
      // 401/403 要读响应体区分「登录失效」与「额度用尽」，不能让 Dio 先抛掉
      validateStatus: (status) => status != null && status < 600,
    ),
  );

  /// 测试注入：替换底层 HTTP adapter
  @visibleForTesting
  set httpClientAdapterForTest(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
  }

  // ── 接口实现 ─────────────────────────────────────────────

  @override
  String get vendorId => templateId;

  @override
  String get kind => AiAccount.kindAutoClaw;

  @override
  String get vendorLabel => 'AutoClaw';

  @override
  bool get supportsSmsLogin => true;

  @override
  Duration get tokenRefreshMargin => refreshMargin;

  @override
  @protected
  Future<List<AiAccount>> Function(String providerId)?
  get accountsLoaderHook => accountsLoaderForTest;

  @override
  @protected
  Future<String?> Function(String providerId)? get accessTokenLoaderHook =>
      accessTokenLoaderForTest;

  @override
  @protected
  Future<void> Function(AiAccount account)? get accountSaverHook =>
      accountSaverForTest;

  @override
  @protected
  Future<AiAccount> Function(AiAccount account)?
  get accountRefresherHook => accountRefresherForTest;

  /// 测试注入：绕开数据库直接给账号列表
  @visibleForTesting
  static Future<List<AiAccount>> Function(String providerId)?
  accountsLoaderForTest;

  // ── token 读取与刷新 ─────────────────────────────────────

  Future<String?> accessTokenFor(String providerId) async {
    final accounts = await accountsFor(providerId);
    if (accounts.isEmpty) return null;
    return accessTokenForAccount(accounts.first);
  }

  /// 测试注入：绕开数据库直接返回 token
  @visibleForTesting
  static Future<String?> Function(String providerId)? accessTokenLoaderForTest;

  /// 测试注入：登录落库（默认写 `ai_accounts` 表）
  @visibleForTesting
  static Future<void> Function(AiAccount account)? accountSaverForTest;

  /// 测试注入：额度/签到 401 后刷新账号（默认走 [refreshAccount]）
  @visibleForTesting
  static Future<AiAccount> Function(AiAccount account)? accountRefresherForTest;

  @override
  Future<AiAccount> reloadAccount(
    String accountId, {
    required bool force,
  }) async {
    final stored = await repository.getById(accountId);
    if (stored == null) {
      evictCachedAccount(accountId);
      throw AccountAuthRequiredException('', message: '账号已删除，请重新登录', kind: kind);
    }
    cacheAccount(stored);
    if (!force && !stored.isStale(margin: refreshMargin) && !stored.isExpired) {
      return stored;
    }
    final refreshToken = stored.refreshToken.trim();
    if (refreshToken.isEmpty) {
      await markAccountExpiredById(accountId);
      throw authExpired(stored.providerId);
    }

    final deviceId = _jwtClaim(refreshToken, 'device_id') ??
        _jwtClaim(stored.accessToken, 'device_id') ??
        '';
    final body = {
      'source_id': product,
      'device_id': deviceId,
      'refresh_token': refreshToken,
    };
    var envelope = await _send(
      'POST',
      '$host/userapi/v1/refresh',
      headers: _bizHeaders(),
      data: body,
    );
    // 国内短信账号走 agent-refresh；旧版 refresh 会以 400002 拒绝
    if (envelope.code == 400002 || envelope.status == 400) {
      envelope = await _send(
        'POST',
        '$host/userapi/v1/agent-refresh',
        headers: _bizHeaders(),
        data: body,
      );
    }
    if (envelope.isAuthRejected || _isDeadRefresh(envelope)) {
      LoggerService.instance.logAI(
        'AutoClaw 刷新登录态失败: HTTP ${envelope.status}',
        level: LogLevel.warning,
        details: envelope.message,
      );
      await markAccountExpiredById(accountId);
      throw authExpired(stored.providerId);
    }
    if (envelope.code != 0 || envelope.data is! Map) {
      throw FormatException(
        envelope.message.isEmpty
            ? '刷新登录态失败（code=${envelope.code}）'
            : envelope.message,
      );
    }
    final data = envelope.data as Map;
    final access = _bareToken(data['access_token']?.toString() ?? '');
    if (access.isEmpty) throw const FormatException('刷新未返回 access_token');
    final rotatedRefresh = _bareToken(data['refresh_token']?.toString() ?? '');
    final nextRefresh = rotatedRefresh.isEmpty ? refreshToken : rotatedRefresh;
    final next = await _accountFromTokens(
      stored.providerId,
      accountId: stored.id,
      access: access,
      refresh: nextRefresh,
      deviceId: deviceId,
      previous: stored,
      fetchProfile: true,
    );
    await saveAccount(next);
    LoggerService.instance.logAI(
      'AutoClaw 登录态已刷新: ${next.label}',
      details: '有效期至 ${next.expiresAt?.toIso8601String() ?? '未知'}',
    );
    return next;
  }

  /// 明确表示 refresh token 已死的业务文案（与插件同口径）
  static bool _isDeadRefresh(_Envelope envelope) {
    final text = envelope.message.toLowerCase();
    return text.contains('invalid_grant') ||
        text.contains('revoked') ||
        text.contains('expired') ||
        envelope.message.contains('登录已失效') ||
        envelope.message.contains('token 失效');
  }

  // ── 短信登录 ─────────────────────────────────────────────

  /// 发送短信验证码，返回本次登录的挑战（device_id 由服务端校验）
  @override
  Future<AccountSmsChallenge> sendLoginCode(
    String providerId,
    String phone,
  ) async {
    final normalized = phone.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(normalized)) {
      throw const FormatException('请输入 11 位手机号（不带 +86）');
    }
    final deviceId = _randomHex(32);
    final envelope = await _send(
      'POST',
      '$host/userapi/v1/agent-send-code',
      headers: _bizHeaders(),
      data: {
        'source_id': product,
        'device_id': deviceId,
        'phone': normalized,
      },
    );
    if (envelope.isAuthRejected || envelope.code != 0) {
      throw FormatException(
        envelope.message.isEmpty
            ? '发送验证码失败（code=${envelope.code}）'
            : envelope.message,
      );
    }
    return AccountSmsChallenge(phone: normalized, ticket: deviceId);
  }

  /// 用短信验证码完成登录（[accountId] 非空表示重新登录已有账号）
  @override
  Future<AiAccount> verifyLoginCode(
    String providerId,
    AccountSmsChallenge challenge,
    String code, {
    String? accountId,
  }) async {
    final digits = code.trim();
    if (!RegExp(r'^\d{4,8}$').hasMatch(digits)) {
      throw const FormatException('请输入短信验证码');
    }
    final deviceId = challenge.ticket;
    final envelope = await _send(
      'POST',
      '$host/userapi/v1/agent-login',
      headers: _bizHeaders(),
      data: {
        'source_id': product,
        'device_id': deviceId,
        'phone': challenge.phone,
        // 厂商按数字类型校验（字符串会返回 400001）
        'code': int.parse(digits),
      },
    );
    if (envelope.isAuthRejected || envelope.code != 0) {
      throw FormatException(
        envelope.message.isEmpty
            ? '登录失败（code=${envelope.code}）'
            : envelope.message,
      );
    }
    final data = envelope.data;
    if (data is! Map) {
      throw FormatException(
        '登录失败：响应缺少账号信息（HTTP ${envelope.status}）',
      );
    }
    final access = _bareToken(data['access_token']?.toString() ?? '');
    final refresh = _bareToken(data['refresh_token']?.toString() ?? '');
    if (access.isEmpty || refresh.isEmpty) {
      throw const FormatException('登录失败：响应缺少 access_token/refresh_token');
    }
    final profile = await _fetchProfile(access, deviceId);
    return _persistLogin(
      providerId,
      access: access,
      refresh: refresh,
      deviceId: deviceId,
      profile: profile,
      accountId: accountId,
      fallbackPhone: challenge.phone,
      uidHint: data['user_id']?.toString() ?? '',
    );
  }

  Future<_AutoClawProfile?> _fetchProfile(
    String access,
    String deviceId,
  ) async {
    try {
      final envelope = await _send(
        'POST',
        '$host/userapi/v1/user-profile',
        headers: _bizHeaders(token: access),
        data: {'source_id': product, 'device_id': deviceId},
      );
      if (envelope.code != 0 || envelope.data is! Map) return null;
      final data = envelope.data as Map;
      return _AutoClawProfile(
        userId: data['user_id']?.toString().trim() ?? '',
        name: data['user_name']?.toString().trim() ?? '',
        phone: data['user_phone']?.toString().trim() ?? '',
      );
    } catch (_) {
      // 昵称/手机号只是卡片展示的加分项，失败不影响登录
      return null;
    }
  }

  /// 落库一个登录态：同一厂商账号重复登录时覆盖旧行，新账号追加到末尾
  Future<AiAccount> _persistLogin(
    String providerId, {
    required String access,
    required String refresh,
    required String deviceId,
    _AutoClawProfile? profile,
    String? accountId,
    String fallbackPhone = '',
    String uidHint = '',
  }) => persistLogin(
    providerId,
    accountId: accountId,
    buildAccount:
        ({
          required String accountId,
          AiAccount? previous,
          required bool fetchProfile,
        }) => _accountFromTokens(
          providerId,
          accountId: accountId,
          access: access,
          refresh: refresh,
          deviceId: deviceId,
          profile: profile,
          previous: previous,
          fallbackPhone: fallbackPhone,
          uidHint: uidHint,
          fetchProfile: fetchProfile,
        ),
  );

  // ── 模型目录 ─────────────────────────────────────────────

  /// AutoClaw 国内的模型由客户端固定目录提供，不额外发请求
  /// 厂商没有模型目录接口，清单与上下文/识图能力取自官方客户端 2.1.0 内置表；
  /// AutoClaw 按积分池计费，不对外暴露逐模型倍率，所以倍率字段留空（不编 1×）。
  static const List<AiProviderModel> _catalog = [
    AiProviderModel(
      id: 'zai_auto',
      name: 'GLM Auto',
      contextWindow: 1048576,
      supportsVision: true,
    ),
    AiProviderModel(
      id: 'zai_auto-fast',
      name: 'GLM Auto Fast',
      contextWindow: 1048576,
      supportsVision: true,
    ),
    AiProviderModel(
      id: 'zaicoding_glm-5.3',
      name: 'GLM-5.3',
      contextWindow: 1048576,
      supportsVision: false,
    ),
    AiProviderModel(
      id: 'zai_glm-5.3-flash',
      name: 'GLM-5.3 Flash',
      contextWindow: 1048576,
      supportsVision: true,
    ),
  ];

  @override
  Future<List<AiProviderModel>> fetchModelsForProvider(
    String providerId,
  ) async {
    final accounts = await accountsFor(providerId, forceReload: true);
    if (accounts.isEmpty) throw notLoggedIn(providerId);
    return List<AiProviderModel>.of(_catalog);
  }

  // ── 账号额度 ─────────────────────────────────────────────

  @override
  Future<AccountQuota> fetchQuota(AiAccount account) =>
      runWithToken(account, _readQuota);

  Future<AccountQuota> _readQuota(String token) async {
    final envelope = await _send(
      'GET',
      '$host/agent-assetmgr/api/v2/wallets?biz_app_id=$product',
      headers: _bizHeaders(token: token),
    );
    _rejectIfUnauthorized(envelope);
    if (envelope.code != 0 || envelope.data is! Map) {
      throw FormatException(
        envelope.message.isEmpty
            ? '查询积分失败（code=${envelope.code}）'
            : envelope.message,
      );
    }
    final data = envelope.data as Map;
    final total = _intOf(data['total_balance']);
    if (total == null) {
      // null/空串按「未知」处理：当成 0 会让卡片显示成已花光
      throw const FormatException('积分响应异常');
    }

    final parts = <String>[];
    final signin = await _readSigninStatus(token);
    if (signin != null) parts.add(signin);
    final wallets = data['wallets'];
    if (wallets is List) {
      for (final row in wallets.whereType<Map>()) {
        if (row['display'] == false) continue;
        final balance = _intOf(row['balance']);
        if (balance == null || balance <= 0) continue;
        final name =
            (row['display_name'] ?? row['public_wallet_type'] ?? '积分')
                .toString()
                .trim();
        if (name.isEmpty) continue;
        // 与总额相同的单钱包不再重复展示
        if ((balance - total).abs() < 1) continue;
        parts.add('$name $balance');
        if (parts.length >= 4) break;
      }
    }

    return AccountQuota(
      balance: total,
      detail: parts.join(' · '),
      fetchedAt: DateTime.now(),
    );
  }

  /// 今日签到状态（容错：任何失败都返回 null，不影响积分展示）
  Future<String?> _readSigninStatus(String token) async {
    try {
      final envelope = await _send(
        'GET',
        '$host/autoclaw-proxy/proxy/autoclaw-task-list',
        headers: _bizHeaders(token: token),
      );
      _rejectIfUnauthorized(envelope);
      if (envelope.code != 0 || envelope.data is! List) return null;
      for (final task in (envelope.data as List).whereType<Map>()) {
        if (task['task_id'] != 'daily_signin') continue;
        final reward = _intOf(task['reward_points']) ?? 0;
        final done = task['status']?.toString() == 'completed';
        if (done) {
          return '每日签到已完成${reward > 0 ? ' +$reward' : ''}';
        }
        return '今日未签到${reward > 0 ? '（+$reward）' : ''}';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── 手动签到 ─────────────────────────────────────────────

  @override
  Future<AccountCheckInResult> checkIn(AiAccount account) =>
      runWithToken(account, _checkInWithToken);

  Future<AccountCheckInResult> _checkInWithToken(String token) async {
    final envelope = await _send(
      'POST',
      '$host/autoclaw-proxy/proxy/autoclaw-task-complete',
      headers: _bizHeaders(token: token),
      data: {'task_id': 'daily_signin', 'source_id': product},
    );
    _rejectIfUnauthorized(envelope);
    final checkedAt = DateTime.now();
    if (envelope.code != 0 || envelope.data is! Map) {
      throw FormatException(
        envelope.message.isEmpty
            ? '签到失败（code=${envelope.code}）'
            : envelope.message,
      );
    }
    final data = envelope.data as Map;
    final reward = _intOf(data['reward_points']) ?? 0;
    final streak = _intOf(data['continuous_days']) ?? 0;
    final suffix = streak > 0 ? ' · 连续 $streak 天' : '';
    if (data['success'] == true) {
      return AccountCheckInResult(
        claimed: true,
        credit: reward,
        message: reward > 0 ? '每日签到 +$reward$suffix' : '签到成功$suffix',
        checkedAt: checkedAt,
      );
    }
    if (data['already_completed'] == true) {
      return AccountCheckInResult(
        claimed: false,
        credit: 0,
        message: reward > 0 ? '今日已签到（+$reward）' : '今日已签到',
        checkedAt: checkedAt,
      );
    }
    throw const FormatException('签到失败：接口未返回签到结果');
  }

  // ── 请求与签名 ───────────────────────────────────────────

  /// 业务接口头（登录/刷新/额度/签到）；WAF 要求带客户端 UA 与签名
  Map<String, String> _bizHeaders({String? token}) {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': '*/*',
      'X-Version': bizVersion,
      'X-Tm': _platformTm(),
      'X-Product': product,
      'X-Auth-Appid': appId,
      'X-Auth-TimeStamp': ts,
      'X-Auth-Sign': _md5('$appId&$ts&$appKey'),
      'X-Trace-Id': _randomHex(16),
      'X-Lang': 'zh-CN',
      'X-Channel': bizChannel,
      // 浏览器禁止脚本设置这几个头，Web 端交给浏览器自己处理
      if (!kIsWeb) ...{
        'User-Agent': 'AutoClaw/$bizVersion (${_platformTag()})',
        'Origin': 'http://localhost:18432',
        'Referer': 'http://localhost:18432/',
      },
    };
    if (token != null && token.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_bareToken(token)}';
    }
    return headers;
  }

  /// 发信层逐请求覆写用的头：OpenAI SDK 形态 + `X-Authorization`
  ///
  /// 返回的 map 里显式把 `Authorization` 置 null，交给 Dio 删除全局头，
  /// 避免把 API Key 模式的旧凭证一起发出去。
  @override
  Map<String, dynamic> requestHeaders(String token, {required String model}) {
    final rid = _randomHex(16);
    final headers = <String, dynamic>{
      ..._bizHeaders(token: token),
      'Accept': 'application/json',
      if (!kIsWeb) 'User-Agent': 'AutoClaw/$cnVersion (${_platformTag()})',
      'X-Channel': cnChannel,
      'X-Version': cnVersion,
      'X-Trace-Id': rid,
      'X-Request-Id': rid,
      'X-Request-Model': model,
      'X-Client-Type': 'pc',
      'x_trace_id': 'autoclaw-desktop',
      'X-Agent-Id': 'main',
      'X-Authorization': 'Bearer ${_bareToken(token)}',
      'Authorization': null,
      'x-goog-api-key': null,
    };
    return headers;
  }

  /// 国内网关要求请求体带官方 system prompt 前缀，且拒收 max_tokens
  @override
  void adaptChatBody(Map<String, dynamic> body, {required String model}) {    body.remove('max_tokens');
    body.remove('max_completion_tokens');
    final messages = body['messages'];
    if (messages is List) {
      for (final message in messages) {
        if (message is! Map) continue;
        message['content'] ??= '';
        message.remove('reasoning_content');
        final toolCalls = message['tool_calls'];
        if (toolCalls is List) {
          for (final call in toolCalls.whereType<Map>()) {
            final function = call['function'];
            if (function is! Map) continue;
            final args = function['arguments'];
            if (args is String) continue;
            // 网关只认字符串形式的 arguments，非字符串一律转 JSON
            function['arguments'] = args == null ? '{}' : jsonEncode(args);
          }
        }
      }
      if (messages.isNotEmpty && messages.first is Map) {
        final first = messages.first as Map;
        if (first['role'] == 'system') {
          final content = first['content'];
          if (content is String) {
            first['content'] = '$officialSystemPrompt\n\n$content';
          } else if (content is List) {
            first['content'] = [
              {'type': 'text', 'text': officialSystemPrompt},
              ...content,
            ];
          } else {
            first['content'] = officialSystemPrompt;
          }
        } else {
          messages.insert(0, {
            'role': 'system',
            'content': officialSystemPrompt,
          });
        }
      }
    }
    if (body['tools'] is! List || (body['tools'] as List).isEmpty) {
      body.remove('tools');
      body.remove('tool_choice');
    }
  }

  Future<_Envelope> _send(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? data,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        url,
        data: data,
        options: Options(method: method, headers: headers),
      );
    } on DioException catch (e) {
      throw FormatException('AutoClaw 请求失败：${e.message ?? e.type.name}');
    }
    final payload = response.data;
    final map = payload is Map ? Map<String, dynamic>.from(payload) : null;
    final status = response.statusCode ?? 0;
    // 2xx/3xx 却没有业务信封，基本是请求被重定向（3xx 空 body）或网关换了回包
    // 形态：显式报错，否则 code 会默认成 0，最后被误报成「登录失败：响应缺少
    // 账号信息」，把真正的 HTTP 状态藏起来。
    if ((map == null || map['code'] == null) && status >= 200 && status < 400) {
      final hint = status >= 300 ? '，请求被重定向，请检查接口地址' : '';
      throw FormatException('AutoClaw 响应异常（HTTP $status$hint）');
    }
    final dataBlock = map?['data'];
    return _Envelope(
      status: status,
      code: _intOf(map?['code']) ?? 0,
      message: (map?['msg'] ?? map?['message'] ?? _messageOfData(dataBlock))
          .toString()
          .trim(),
      data: dataBlock,
    );
  }

  static String _messageOfData(dynamic data) {
    if (data is Map) {
      final message = data['message'] ?? data['msg'];
      if (message != null) return message.toString();
    }
    return '';
  }

  void _rejectIfUnauthorized(_Envelope envelope) {
    if (envelope.isAuthRejected) throw const AccountAuthTokenRejected();
  }

  // ── 内部 ─────────────────────────────────────────────────

  Future<AiAccount> _accountFromTokens(
    String providerId, {
    required String accountId,
    required String access,
    required String refresh,
    required String deviceId,
    _AutoClawProfile? profile,
    AiAccount? previous,
    String fallbackPhone = '',
    String uidHint = '',
    bool fetchProfile = false,
  }) async {
    final cleanAccess = _bareToken(access);
    final claims = _decodeJwtClaims(cleanAccess);
    final now = DateTime.now();
    final freshProfile = fetchProfile && profile == null
        ? await _fetchProfile(cleanAccess, deviceId)
        : null;
    final effectiveProfile = profile ?? freshProfile;
    final maskedPhone = _maskPhone(
      _firstNonEmpty([effectiveProfile?.phone ?? '', fallbackPhone]),
    );
    return AiAccount(
      id: accountId,
      providerId: providerId,
      kind: AiAccount.kindAutoClaw,
      alias: previous?.alias ?? '',
      accessToken: cleanAccess,
      refreshToken: refresh.trim(),
      expiresAt: _jwtExpiry(claims),
      uid: _firstNonEmpty([
        effectiveProfile?.userId ?? '',
        uidHint,
        _extractUid(claims),
      ]),
      displayName: effectiveProfile?.name ?? _extractName(claims),
      phone: maskedPhone.isNotEmpty ? maskedPhone : (previous?.phone ?? ''),
      status: AiAccount.statusActive,
      enabled: previous?.enabled ?? true,
      sortOrder: previous?.sortOrder ?? 0,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
  }

  static String _platformTag() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return 'mac-arm64';
      case TargetPlatform.windows:
        return 'win-x64';
      default:
        // Android/Linux 与插件的 linux 口径一致
        return 'linux-arm64';
    }
  }

  static String _platformTm() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return 'mac';
      case TargetPlatform.windows:
        return 'win';
      default:
        return 'linux';
    }
  }

  static final Random _random = Random.secure();

  static String _randomHex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _md5(String input) =>
      md5.convert(utf8.encode(input)).toString();

  static String _bareToken(String value) {
    var trimmed = value.trim();
    while (trimmed.toLowerCase().startsWith('bearer ')) {
      trimmed = trimmed.substring(7).trim();
    }
    return trimmed;
  }

  static int? _intOf(dynamic raw) {
    if (raw == null) return null;
    final number = num.tryParse(raw.toString().trim());
    if (number == null || !number.isFinite) return null;
    return number.floor();
  }

  static Map<String, dynamic>? _decodeJwtClaims(String token) {
    final parts = token.split('.');
    if (parts.length < 2 || parts[1].isEmpty) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final value = jsonDecode(decoded);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _jwtClaim(String token, String key) {
    final value = _decodeJwtClaims(_bareToken(token))?[key];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static DateTime? _jwtExpiry(Map<String, dynamic>? claims) {
    final exp = claims?['exp'];
    final seconds = exp is num ? exp.toInt() : int.tryParse('${exp ?? ''}');
    if (seconds == null || seconds <= 0) return null;
    // 提前 10 分钟视为过期：refresh token 一次一换，临期再刷新等于多烧一次
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
        .subtract(expirySkew);
  }

  static String _extractUid(Map<String, dynamic>? claims) {
    if (claims == null) return '';
    for (final key in ['sub', 'user_id', 'uid', 'id']) {
      final value = claims[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _extractName(Map<String, dynamic>? claims) =>
      claims?['name']?.toString().trim() ?? '';

  static String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      if (value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  static String _maskPhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0086') && digits.length - 4 >= 7) {
      digits = digits.substring(4);
    } else if (digits.startsWith('86') && digits.length - 2 >= 7) {
      digits = digits.substring(2);
    }
    if (digits.length < 11) return '';
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }

  // ── 测试用入口 ───────────────────────────────────────────

  @visibleForTesting
  static Map<String, dynamic> requestHeadersForTest(
    String token, {
    String model = 'zai_auto',
  }) =>
      AutoClawAuthService.instance.requestHeaders(token, model: model);

  @visibleForTesting
  static void adaptChatBodyForTest(
    Map<String, dynamic> body, {
    String model = 'zai_auto',
  }) => AutoClawAuthService.instance.adaptChatBody(body, model: model);

  @visibleForTesting
  static Map<String, dynamic>? decodeJwtForTest(String token) =>
      _decodeJwtClaims(_bareToken(token));

  @visibleForTesting
  static String maskPhoneForTest(String raw) => _maskPhone(raw);

  @visibleForTesting
  void resetForTest() {
    clearCache();
    clearRefreshLocks();
    accessTokenLoaderForTest = null;
    accountsLoaderForTest = null;
    accountSaverForTest = null;
    accountRefresherForTest = null;
  }
}

/// 一次 AutoClaw 接口响应（不抛 HTTP 异常，由调用方按 status/code 判定）
class _Envelope {
  final int status;
  final int code;
  final String message;
  final dynamic data;

  const _Envelope({
    required this.status,
    required this.code,
    required this.message,
    required this.data,
  });

  /// 401/403 是登录失效；403 的「额度用尽」是账号量用完，不是登录问题
  bool get isAuthRejected {
    if (status != 401 && status != 403) return false;
    if (status == 403 && _isQuotaExhausted) return false;
    return true;
  }

  bool get _isQuotaExhausted {
    final text = message;
    if (text.contains('额度') ||
        text.contains('余额') ||
        text.contains('用完') ||
        text.contains('用尽')) {
      return true;
    }
    final lower = text.toLowerCase();
    return lower.contains('quota') ||
        lower.contains('insufficient') ||
        lower.contains('exhausted') ||
        code == 810000;
  }
}

class _AutoClawProfile {
  final String userId;
  final String name;
  final String phone;

  const _AutoClawProfile({
    required this.userId,
    required this.name,
    required this.phone,
  });
}