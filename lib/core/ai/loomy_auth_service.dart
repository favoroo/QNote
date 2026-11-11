import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show protected, visibleForTesting;
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/ai/account_auth_service_base.dart';
import 'package:qnote_flutter/core/ai/account_auth_types.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/utils/image_model_detection.dart';
import 'package:qnote_flutter/models/account_checkin_result.dart';
import 'package:qnote_flutter/models/account_quota.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

export 'package:qnote_flutter/core/ai/account_auth_types.dart';

/// Loomy（讯飞，`loomyad.xunfei.cn`）订阅账号的登录、额度与签到
///
/// 接口与请求形态来自 magpie 社区插件 `@magpie-community/opencode-loomy-auth`：
/// - 登录：讯飞账号域 `POST {account}/login/phone/sendMsgCode` →
///   `POST {account}/login/phone/checkCode`，两个接口都要 HMAC-SHA1 签名头；
/// - 无续期接口：session 固定 14 天，过期只能重新登录（短信或粘贴）；
/// - 聊天：`POST {gateway}/api/v1/chat/completions`，同时带 `token` 与
///   `Authorization`，`Content-Type` 必须带 `charset=utf-8`；
/// - 额度：`GET /api/v2/points/records` 的永久积分 + 每日赠送积分两个钱包；
/// - 签到：`POST /api/v1/points/first-login`，按天幂等，靠调用前后每日余额差
///   判断「今天真领到了」还是「今天已经领过」。
///
/// 与发信层的契约和其他账号型厂商一致：token 不落 `api_keys`、不参与 WebDAV
/// 同步与备份导出；多账号选号复用同一个 [RaccoonAccountRouter]。
class LoomyAuthService extends AccountAuthServiceBase {
  LoomyAuthService._();

  static final LoomyAuthService instance = LoomyAuthService._();

  /// 厂商模板 id（`lib/config/models.dart` 与 `ai_providers.vendor_id`）
  static const String templateId = 'loomy';

  /// 积分/签到/模型网关（也是聊天基址的来源）
  static const String gatewayHost = 'https://loomyad.xunfei.cn';

  /// 聊天基址：与厂商模板的 defaultBaseUrl 保持一致，发信层再拼 chat/completions
  static const String chatBase = '$gatewayHost/api/v1';

  /// 讯飞账号域（登录链路的 host，HMAC 签名）
  static const String accountHost = 'https://account.xfinfr.com';

  /// 账号域客户端凭据（插件内置常量，属客户端指纹复现，不是安全边界）
  static const String accessKeyId = '2thryby66wxi53sk';
  static const String accessKeySecret = 'zsak6eadrbawz683wf5r3m2snrwj868r';
  static const String appId = 'GM3LOOMY';

  /// 业务码：成功与「登录态失效」两种（与插件同口径）
  static const String codeOk = '000000';
  static const Set<String> authCodes = {'020002', '100002'};

  /// 短信验证码长度（厂商只发 6 位）
  static const int smsCodeLength = 6;

  /// 客户端申请的 session 有效期：14 天，且没有续期接口
  static const Duration sessionTtl = Duration(days: 14);

  /// 提前多久视为临期：没有续期接口，临期 token 直接提示重新登录比发信失败更省事
  static const Duration expiryMargin = Duration(hours: 1);

  /// 静态模型目录（登录前可用；登录后以 `/api/v1/models` 实时目录为准）
  static const List<AiProviderModel> _catalog = [
    AiProviderModel(id: 'DeepSeek-V4.1-Flash', name: 'DeepSeek V4.1 Flash'),
    AiProviderModel(id: 'deepseek-v4-flash-0731', name: 'DeepSeek V4 Flash 0731'),
    AiProviderModel(id: 'MiniMax-M3', name: 'MiniMax M3'),
    AiProviderModel(id: 'Kimi-k2.6', name: 'Kimi k2.6'),
    AiProviderModel(id: 'qwen-3.8-max', name: 'Qwen 3.8 Max'),
    AiProviderModel(id: 'GLM-5.3-Flash', name: 'GLM 5.3 Flash'),
    AiProviderModel(id: 'qwen3.8-flash', name: 'qwen 3.8 flash'),
    AiProviderModel(id: 'spark-x', name: 'Spark-X2.5'),
    AiProviderModel(id: 'mimo-v2.5', name: 'MiMo V2.5'),
    AiProviderModel(id: 'auto', name: '自动 · 均衡'),
  ];

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
  String get kind => AiAccount.kindLoomy;

  @override
  String get vendorLabel => 'Loomy';

  @override
  bool get supportsSmsLogin => true;

  @override
  int get smsCodeMaxLength => smsCodeLength;

  /// Loomy 没有续期接口，刷新只是检查登录态是否还活着
  @override
  bool get supportsTokenRefresh => false;

  @override
  Duration get tokenRefreshMargin => expiryMargin;

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

  /// Loomy 的登录态是固定 14 天的 session，到期只能重新登录
  @override
  AccountAuthRequiredException authExpired(String providerId) =>
      AccountAuthRequiredException(
        providerId,
        message: 'Loomy 登录已失效，请重新登录（session 有效期 14 天，到期需重登）',
        kind: kind,
      );

  /// 测试注入：绕开数据库直接给账号列表
  @visibleForTesting
  static Future<List<AiAccount>> Function(String providerId)?
  accountsLoaderForTest;

  // ── token 读取 ───────────────────────────────────────────

  /// Loomy 没有续期接口：临期/过期的账号直接判失效，让用户重新登录
  ///
  /// 不在这里自动重登——短信验证码必须用户自己收，服务端也无法凭空续期。
  @override
  Future<String?> accessTokenForAccount(AiAccount account) async {
    final loader = accessTokenLoaderHook;
    if (loader != null) return loader(account.providerId);

    final current = accountsLoaderHook != null
        ? account
        : await refreshCacheFromStore(account);
    if (current.accessToken.trim().isEmpty) return null;
    if (current.isExpired) return null;
    if (current.isStale(margin: expiryMargin)) {
      // 临期也视为失效：带着快要过期的 session 发信，长对话中途断掉更难解释
      await markAccountExpired(current);
      return null;
    }
    return current.accessToken;
  }

  /// 测试注入：绕开数据库直接返回 token
  @visibleForTesting
  static Future<String?> Function(String providerId)? accessTokenLoaderForTest;

  /// 测试注入：登录落库（默认写 `ai_accounts` 表）
  @visibleForTesting
  static Future<void> Function(AiAccount account)? accountSaverForTest;

  /// Loomy 无续期接口：刷新等同于「检查登录态是否还活着」
  ///
  /// 未过期就原样返回（顺带更新缓存）；已过期直接抛「请重新登录」。
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
    if (stored.isExpired || stored.isStale(margin: expiryMargin)) {
      await markAccountExpired(stored);
      throw authExpired(stored.providerId);
    }
    return stored;
  }

  // ── 短信登录 ─────────────────────────────────────────────

  /// 发送短信验证码；返回的 [AccountSmsChallenge.ticket] 是发码接口给的 msgid
  @override
  Future<AccountSmsChallenge> sendLoginCode(
    String providerId,
    String phone,
  ) async {
    final normalized = normalizePhone(phone);
    if (normalized == null) {
      throw const FormatException('请输入 11 位中国大陆手机号');
    }
    final envelope = await _signedPost('/login/phone/sendMsgCode', {
      'base': _makeBase(),
      'param': {'ccode': '86', 'phone': normalized, 'expire': 300},
    });
    if (envelope.code != codeOk) {
      throw FormatException(
        envelope.message.isEmpty
            ? '验证码发送失败（code=${envelope.code}）'
            : '验证码发送失败：${envelope.message}',
      );
    }
    final msgid = envelope.data is Map
        ? (envelope.data as Map)['msgid']?.toString().trim() ?? ''
        : '';
    if (msgid.isEmpty) {
      throw const FormatException('验证码已发送，但上游没有返回 msgid，请重试');
    }
    return AccountSmsChallenge(phone: normalized, ticket: msgid);
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
    if (!RegExp('^\\d{$smsCodeLength}\$').hasMatch(digits)) {
      throw const FormatException('请输入 6 位数字验证码');
    }
    final envelope = await _signedPost('/login/phone/checkCode', {
      'base': _makeBase(),
      'param': {
        'ccode': '86',
        'phone': challenge.phone,
        'mcode': digits,
        'msgid': challenge.ticket,
        // 客户端申请的 session 有效期（秒），与 [sessionTtl] 一致
        'expire': sessionTtl.inSeconds,
      },
    });
    if (authCodes.contains(envelope.code)) {
      throw const FormatException('登录失败：登录态已失效，请重新获取验证码');
    }
    if (envelope.code != codeOk) {
      throw FormatException(
        envelope.message.isEmpty
            ? '登录失败（code=${envelope.code}）'
            : '登录失败：${envelope.message}',
      );
    }
    final data = envelope.data;
    if (data is! Map) throw const FormatException('登录失败：响应缺少账号信息');
    final session = (data['session']?.toString() ?? '').trim();
    if (session.isEmpty) {
      throw const FormatException('登录成功但上游没有返回 session');
    }
    return _persistLogin(
      providerId,
      session: session,
      phone: challenge.phone,
      uidHint: data['userid']?.toString() ?? '',
      accountId: accountId,
    );
  }

  /// 落库一个登录态：同一账号重复登录时覆盖旧行，新账号追加到末尾
  Future<AiAccount> _persistLogin(
    String providerId, {
    required String session,
    required String phone,
    String uidHint = '',
    String? accountId,
  }) {
    final maskedPhone = maskPhone(phone);
    return persistLogin(
      providerId,
      accountId: accountId,
      buildAccount:
          ({
            required String accountId,
            AiAccount? previous,
            required bool fetchProfile,
          }) async => _accountFromSession(
            providerId,
            accountId: accountId,
            session: session,
            maskedPhone: maskedPhone,
            uidHint: uidHint,
            previous: previous,
          ),
    );
  }

  AiAccount _accountFromSession(
    String providerId, {
    required String accountId,
    required String session,
    required String maskedPhone,
    String uidHint = '',
    AiAccount? previous,
  }) {
    final now = DateTime.now();
    return AiAccount(
      id: accountId,
      providerId: providerId,
      kind: AiAccount.kindLoomy,
      alias: previous?.alias ?? '',
      accessToken: session.trim(),
      // 厂商没有 refresh 接口：留空，刷新逻辑据「无 refreshToken」直接判失效
      refreshToken: '',
      // session 是固定 14 天的不透明串（不是 JWT），只能按登录时刻推算
      expiresAt: now.add(sessionTtl),
      uid: uidHint.trim().isNotEmpty ? uidHint.trim() : (previous?.uid ?? ''),
      displayName: previous?.displayName ?? '',
      phone: maskedPhone.isNotEmpty ? maskedPhone : (previous?.phone ?? ''),
      status: AiAccount.statusActive,
      enabled: previous?.enabled ?? true,
      sortOrder: previous?.sortOrder ?? 0,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
  }

  // ── 模型目录 ─────────────────────────────────────────────

  /// 登录后以厂商实时目录为准；请求失败时回落到静态目录，不让设置页空着
  @override
  Future<List<AiProviderModel>> fetchModelsForProvider(
    String providerId,
  ) async {
    final accounts = await accountsFor(providerId, forceReload: true);
    if (accounts.isEmpty) throw notLoggedIn(providerId);
    final token = await accessTokenForAccount(accounts.first);
    if (token == null || token.trim().isEmpty) throw authExpired(providerId);
    try {
      final envelope = await _tokenRequest('GET', '/api/v1/models', token);
      if (envelope.code.isNotEmpty && envelope.code != codeOk) {
        return List<AiProviderModel>.of(_catalog);
      }
      final entries = envelope.data;
      if (entries is! List) return List<AiProviderModel>.of(_catalog);
      final models = <AiProviderModel>[];
      final seen = <String>{};
      for (final entry in entries.whereType<Map>()) {
        final id = (entry['id'] ?? '').toString().trim();
        if (id.isEmpty || !seen.add(id)) continue;
        final rawName = (entry['name'] ?? entry['display_name'] ?? id)
            .toString()
            .trim();
        // 倍率只藏在展示名尾部（`Kimi k2.6 (x6.5)`）：拆出来单独存，
        // 界面才能像其他厂商一样把「免费 / 倍率」当徽标展示
        final split = splitRateSuffix(rawName);
        models.add(
          AiProviderModel.of(
            id,
            name: split.name,
            rate: _rateOf(split.rate),
            contextWindow: _contextOf(entry),
            supportsVision: _visionOf(entry),
            supportsImageGeneration: imageGenerationFromCatalogEntry(entry),
          ),
        );
      }
      return models.isEmpty ? List<AiProviderModel>.of(_catalog) : models;
    } catch (e) {
      LoggerService.instance.logAI(
        'Loomy 模型目录拉取失败，回落静态目录: $e',
        level: LogLevel.warning,
      );
      return List<AiProviderModel>.of(_catalog);
    }
  }

  // ── 账号额度 ─────────────────────────────────────────────

  @override
  Future<AccountQuota> fetchQuota(AiAccount account) async {
    final token = await accessTokenForAccount(account);
    if (token == null || token.trim().isEmpty) {
      throw notLoggedIn(account.providerId);
    }
    final envelope = await _tokenRequest(
      'GET',
      '/api/v2/points/records?pageNo=1&pageSize=1&direction=debit&granularity=chat',
      token,
    );
    _rejectIfAuthCode(envelope, account.providerId);
    if (envelope.code != codeOk) {
      throw FormatException(
        envelope.message.isEmpty
            ? '积分查询失败（code=${envelope.code}）'
            : '积分查询失败：${envelope.message}',
      );
    }
    // 该接口是「积分流水」，响应里没有余额字段是常态：这时必须报「未知」，
    // 不能冒充 0（卡片显示 0 会让人以为积分已经花光）
    final data = envelope.data;
    final balance = _intOf(data is Map ? data['balance'] : null);
    final daily = _intOf(data is Map ? data['dailyBalance'] : null);
    final dailyLimit = _intOf(data is Map ? data['dailyLimitPoints'] : null);
    final dailyRemaining = _intOf(
      data is Map ? data['dailyRemainingPoints'] : null,
    );
    if (balance == null && daily == null && dailyRemaining == null) {
      throw const FormatException('积分响应没有返回余额字段');
    }

    final parts = <String>[];
    if (dailyLimit != null && dailyRemaining != null) {
      parts.add('每日赠送 $dailyRemaining/$dailyLimit');
    } else if (daily != null) {
      parts.add('每日赠送 $daily');
    }
    if (balance != null) parts.add('永久 $balance');

    return AccountQuota(
      // 主数值用两个钱包之和：单看永久积分会漏掉每天赠送的那部分
      balance: (balance ?? 0) +
          (dailyRemaining ?? daily ?? 0),
      detail: parts.join(' · '),
      fetchedAt: DateTime.now(),
    );
  }

  // ── 手动签到 ─────────────────────────────────────────────

  /// 每日首登赠送：接口按天幂等，重复调用也返回成功
  ///
  /// 是否真领到要靠调用前后的每日余额差判断——只看 code 会把「今天已领过」
  /// 也报成「签到成功 +N」，等于虚报奖励。
  @override
  Future<AccountCheckInResult> checkIn(AiAccount account) async {
    final token = await accessTokenForAccount(account);
    if (token == null || token.trim().isEmpty) {
      throw notLoggedIn(account.providerId);
    }
    final before = await _readDailyBalance(token);
    final envelope = await _tokenRequest(
      'POST',
      '/api/v1/points/first-login',
      token,
      data: const <String, dynamic>{},
    );
    _rejectIfAuthCode(envelope, account.providerId);
    final checkedAt = DateTime.now();
    if (envelope.code != codeOk) {
      throw FormatException(
        envelope.message.isEmpty
            ? '每日积分刷新失败（code=${envelope.code}）'
            : '每日积分刷新失败：${envelope.message}',
      );
    }
    final fromBody = envelope.data is Map
        ? _intOf((envelope.data as Map)['dailyBalance'])
        : null;
    final after = fromBody ?? await _readDailyBalance(token);
    if (before != null && after != null && after > before) {
      final gained = after - before;
      return AccountCheckInResult(
        claimed: true,
        credit: gained,
        message: '每日赠送积分 +$gained（当前 $after）',
        checkedAt: checkedAt,
      );
    }
    // 余额读不到时只能说「已刷新」：没有前后对比就断言「今天领过」同样是虚报
    final suffix = after != null ? '（当前 $after）' : '';
    final comparable = before != null && after != null;
    return AccountCheckInResult(
      claimed: false,
      credit: 0,
      message: comparable ? '今日已领取$suffix' : '每日积分已刷新$suffix',
      checkedAt: checkedAt,
    );
  }

  /// 读当前每日赠送余额（签到前后对比用；失败返回 null，不阻断签到）
  Future<int?> _readDailyBalance(String token) async {
    try {
      final envelope = await _tokenRequest(
        'GET',
        '/api/v2/points/records?pageNo=1&pageSize=1&direction=debit&granularity=chat',
        token,
      );
      if (envelope.code != codeOk || envelope.data is! Map) return null;
      return _intOf((envelope.data as Map)['dailyBalance']);
    } catch (_) {
      return null;
    }
  }

  void _rejectIfAuthCode(_LoomyEnvelope envelope, String providerId) {
    if (envelope.status == 401 || envelope.status == 403) {
      throw authExpired(providerId);
    }
    if (authCodes.contains(envelope.code)) throw authExpired(providerId);
  }

  // ── 请求与签名 ───────────────────────────────────────────

  /// 发信层逐请求覆写用的头
  ///
  /// Loomy 网关认两种凭证头，客户端两个都发；`Content-Type` 必须带
  /// `charset=utf-8`，否则上游按 GBK 解码，中文会变成乱码。
  @override
  Map<String, dynamic> requestHeaders(String token, {required String model}) {
    final clean = _bareToken(token);
    return {
      'Content-Type': 'application/json;charset=utf-8',
      'token': clean,
      'Authorization': 'Bearer $clean',
      'x-goog-api-key': null,
    };
  }

  /// 网关只认 low/medium/high 三档思考强度；旧版 DeepSeek 只认图片标记
  @override
  void adaptChatBody(Map<String, dynamic> body, {required String model}) {
    foldReasoning(body);
    if (prefersTagFormat(model)) rewriteImagesToTags(body);
  }

  /// 账号域客户端信封（登录链路要按客户端原样带）
  static Map<String, dynamic> _makeBase() => {
    'appid': appId,
    'modelid': 'Web',
    'version': '1.0.0',
    'devid': 'web',
    'ua': 'Loomy|Desktop|Electron|macOS',
    'traceid': _randomHex(16),
  };

  /// 账号域的 HMAC-SHA1 签名头（9 段待签串，后两段固定为空）
  @visibleForTesting
  static Map<String, String> signHeaders(
    String method,
    String path,
    String body,
  ) {
    final contentMd5 = body.isEmpty
        ? ''
        : base64Encode(md5.convert(utf8.encode(body)).bytes);
    final date = _utcDateString(DateTime.now().toUtc());
    final nonce = const Uuid().v4();
    final stringToSign = [
      method.toUpperCase(),
      _escapedPath(path),
      '',
      contentMd5,
      'application/json',
      date,
      nonce,
      '',
      '',
    ].join('\n');
    final signature = base64Encode(
      Hmac(sha1, utf8.encode(accessKeySecret))
          .convert(utf8.encode(stringToSign))
          .bytes,
    );
    final headers = <String, String>{
      'Authorization': 'account $accessKeyId:$signature',
      'Date': date,
      'Nonce': nonce,
      'Content-Type': 'application/json',
    };
    if (contentMd5.isNotEmpty) headers['Content-MD5'] = contentMd5;
    return headers;
  }

  /// 签名要求路径按段百分号编码（与客户端一致，`!'()*` 也要转义）
  @visibleForTesting
  static String escapedPath(String path) => _escapedPath(path);

  static String _escapedPath(String path) {
    var clean = path.startsWith('/') ? path : '/$path';
    if (clean.length > 1 && clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean.split('/').map(_escapeSegment).join('/');
  }

  static String _escapeSegment(String segment) {
    // Uri.encodeComponent 保留 !'()* 原样，客户端签名时会把它们转成 %XX
    return Uri.encodeComponent(segment).replaceAllMapped(
      RegExp(r"[!'()*]"),
      (match) => '%${match[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
    );
  }

  static String _utcDateString(DateTime utc) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int value) => value.toString().padLeft(2, '0');
    return '${weekdays[utc.weekday - 1]}, ${two(utc.day)} '
        '${months[utc.month - 1]} ${utc.year} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
  }

  /// 账号域的一次签名 POST（登录链路）
  ///
  /// 签名必须覆盖实际发出的字节，所以 body 只序列化一次。
  Future<_LoomyEnvelope> _signedPost(String path, Map<String, dynamic> body) async {
    final bodyString = jsonEncode(body);
    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        '$accountHost$path',
        data: bodyString,
        options: Options(
          method: 'POST',
          headers: signHeaders('POST', path, bodyString),
        ),
      );
    } on DioException catch (e) {
      throw FormatException('Loomy 账号接口请求失败：${e.message ?? e.type.name}');
    }
    final payload = response.data;
    final map = payload is Map ? Map<String, dynamic>.from(payload) : null;
    if (map == null) {
      throw FormatException(
        'Loomy 账号接口返回了无法解析的内容（HTTP ${response.statusCode}）',
      );
    }
    final envelope = _LoomyEnvelope.from(
      status: response.statusCode ?? 0,
      payload: map,
    );
    if ((response.statusCode ?? 0) >= 400) {
      throw FormatException(
        'Loomy 账号接口返回 HTTP ${response.statusCode}'
        '${envelope.message.isEmpty ? '' : '：${envelope.message}'}',
      );
    }
    return envelope;
  }

  /// 网关的一次请求：同时带 `token` 与 `Authorization`
  Future<_LoomyEnvelope> _tokenRequest(
    String method,
    String path,
    String token, {
    Map<String, dynamic>? data,
  }) async {
    final clean = _bareToken(token);
    if (clean.isEmpty) throw authExpired('');
    final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        '$gatewayHost$path',
        data: data,
        options: Options(
          method: method,
          headers: {
            'Content-Type': 'application/json;charset=utf-8',
            'token': clean,
            'Authorization': 'Bearer $clean',
          },
        ),
      );
    } on DioException catch (e) {
      throw FormatException('Loomy 请求失败：${e.message ?? e.type.name}');
    }
    final payload = response.data;
    final map = payload is Map ? Map<String, dynamic>.from(payload) : null;
    if (map == null) throw const FormatException('Loomy 接口返回了无法解析的内容');
    return _LoomyEnvelope.from(
      status: response.statusCode ?? 0,
      payload: map,
    );
  }

  // ── 内部 ─────────────────────────────────────────────────

  static final Random _random = Random.secure();

  static String _randomHex(int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

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

  /// 手机号规范化（与客户端一致：去掉空格/横线与 +86 前缀）
  @visibleForTesting
  static String? normalizePhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'[\s-]'), '');
    if (digits.startsWith('+86')) digits = digits.substring(3);
    if (digits.length == 13 && digits.startsWith('86')) digits = digits.substring(2);
    if (RegExp(r'^1[3-9]\d{9}$').hasMatch(digits)) return digits;
    return null;
  }

  /// 脱敏手机号；不足 11 位返回空串（宁可留空也不要展示半截号码）
  @visibleForTesting
  static String maskPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 11) return '';
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }

  /// 展示名尾部倍率 `(x3.0)` 拆出来（Loomy 用倍率表示积分消耗）
  @visibleForTesting
  static ({String name, String? rate}) splitRateSuffix(String raw) {
    final trimmed = raw.trimRight();
    for (final pair in [
      (')', '('),
      ('）', '（'),
    ]) {
      if (!trimmed.endsWith(pair.$1)) continue;
      final body = trimmed.substring(0, trimmed.length - 1);
      final at = body.lastIndexOf(pair.$2);
      if (at < 0) continue;
      final inner = body.substring(at + 1).trim();
      if (!RegExp(r'^x\d+(\.\d+)?$', caseSensitive: false).hasMatch(inner)) {
        return (name: trimmed, rate: null);
      }
      final bare = body.substring(0, at).trimRight();
      return (name: bare.isEmpty ? trimmed : bare, rate: inner.toLowerCase());
    }
    return (name: trimmed, rate: null);
  }

  /// 倍率后缀（`x6.5`）→ 数值；解析不出返回 null（当作厂商没给倍率）
  static num? _rateOf(String? suffix) {
    if (suffix == null || suffix.trim().isEmpty) return null;
    return num.tryParse(suffix.trim().replaceFirst(RegExp(r'^[xX]'), ''));
  }

  /// 上下文窗口：实时目录给 `context_length`，旧版/兼容字段一并兜住
  static int? _contextOf(Map<dynamic, dynamic> entry) {
    final limit = entry['limit'];
    final raw =
        entry['context_window'] ??
        entry['context_length'] ??
        (limit is Map ? limit['context'] : null);
    if (raw is num) return raw.floor();
    return num.tryParse(raw?.toString().trim() ?? '')?.floor();
  }

  /// 视觉能力：优先 `capabilities.vision`，其次看输入模态里有没有图像
  ///
  /// 两者都没有时返回 null；厂商没有明确声明就不替它下结论。
  static bool? _visionOf(Map<dynamic, dynamic> entry) {
    final caps = entry['capabilities'];
    if (caps is! Map) return null;
    final vision = caps['vision'];
    if (vision is bool) return vision;
    final modalities = caps['input_modalities'];
    if (modalities is! List) return null;
    return modalities.any(
      (item) => item.toString().trim().toLowerCase() == 'image',
    );
  }

  /// 旧版 DeepSeek 只认 `<image_base64>` 标记，不认 OpenAI 的 image_url 分段
  ///
  /// `deepseek-v4-flash-0731` 走标记；`DeepSeek-V4.1-Flash` 收 image_url，
  /// 把标记当纯文本读（会变成 1 万 prompt token + 空回复），必须排除。
  @visibleForTesting
  static bool prefersTagFormat(String model) {
    final name = model.toLowerCase();
    if (!name.contains('deepseek')) return false;
    return !RegExp(r'v4[.-]1(?![0-9])').hasMatch(name);
  }

  /// 把 data-URI 图片分段改写成 `<image_base64>` 标记并并入相邻文本
  ///
  /// 返回改写数量（0 表示没有可改写的图片）。
  @visibleForTesting
  static int rewriteImagesToTags(Map<String, dynamic> body) {
    final messages = body['messages'];
    if (messages is! List) return 0;
    var converted = 0;
    for (final message in messages.whereType<Map>()) {
      final content = message['content'];
      if (content is! List) continue;
      for (var i = content.length - 1; i >= 0; i--) {
        final part = content[i];
        if (part is! Map) continue;
        final kind = (part['type'] ?? '').toString().trim().toLowerCase();
        if (kind != 'image_url' && kind != 'input_image') continue;
        final rawUrl = part['image_url'];
        final url = rawUrl is String ? rawUrl : (rawUrl is Map ? rawUrl['url'] : null);
        if (url is! String || !url.startsWith('data:')) continue;
        final tag = '<image_base64>$url</image_base64>';
        content.removeAt(i);
        final prev = i > 0 && content[i - 1] is Map && content[i - 1]['type'] == 'text'
            ? content[i - 1] as Map
            : null;
        if (prev != null) {
          prev['text'] = '${prev['text']}\n$tag';
        } else if (i < content.length &&
            content[i] is Map &&
            content[i]['type'] == 'text') {
          final next = content[i] as Map;
          next['text'] = '$tag\n${next['text']}';
        } else {
          content.insert(i, {'type': 'text', 'text': tag});
        }
        converted++;
      }
    }
    return converted;
  }

  /// 思考档折叠：Loomy 只认 low/medium/high，超档与未知档一律删掉
  ///
  /// 返回是否改动过请求体（便于日志判断这次请求被适配了）。
  @visibleForTesting
  static bool foldReasoning(Map<String, dynamic> body) {
    var changed = false;
    String? fold(dynamic raw) {
      switch (raw) {
        case 'minimal':
        case 'low':
          return 'low';
        case 'medium':
          return 'medium';
        case 'high':
        case 'max':
          return 'high';
      }
      return null;
    }

    final effort = body['reasoning_effort'];
    if (effort is String) {
      final folded = fold(effort);
      if (folded != effort) {
        if (folded != null) {
          body['reasoning_effort'] = folded;
        } else {
          body.remove('reasoning_effort');
        }
        changed = true;
      }
    }
    final reasoning = body['reasoning'];
    if (reasoning is Map && reasoning['effort'] is String) {
      final folded = fold(reasoning['effort']);
      if (folded != reasoning['effort']) {
        if (folded != null) {
          reasoning['effort'] = folded;
        } else {
          reasoning.remove('effort');
        }
        changed = true;
      }
    }
    return changed;
  }

  // ── 测试用入口 ───────────────────────────────────────────

  @visibleForTesting
  static Map<String, dynamic> requestHeadersForTest(
    String token, {
    String model = 'auto',
  }) => LoomyAuthService.instance.requestHeaders(token, model: model);

  @visibleForTesting
  void resetForTest() {
    clearCache();
    accessTokenLoaderForTest = null;
    accountsLoaderForTest = null;
    accountSaverForTest = null;
  }
}

/// 一次 Loomy 响应（不抛 HTTP 异常，由调用方按 status/code 判定）
class _LoomyEnvelope {
  final int status;
  final String code;
  final String message;
  final dynamic data;

  const _LoomyEnvelope({
    required this.status,
    required this.code,
    required this.message,
    required this.data,
  });

  factory _LoomyEnvelope.from({
    required int status,
    required Map<String, dynamic> payload,
  }) {
    final rawData = payload['data'];
    return _LoomyEnvelope(
      status: status,
      code: (payload['code'] ?? '').toString().trim(),
      message: (payload['desc'] ?? payload['message'] ?? '').toString().trim(),
      // 积分流水接口把真正的数据放在 data.data 里
      data: rawData is Map && rawData['data'] is Map ? rawData['data'] : rawData,
    );
  }
}
