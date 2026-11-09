import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/ai/account_auth_types.dart';
import 'package:qnote_flutter/core/ai/raccoon_account_router.dart';
import 'package:qnote_flutter/core/ai/raccoon_login.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/core/utils/image_model_detection.dart';
import 'package:qnote_flutter/models/account_checkin_result.dart';
import 'package:qnote_flutter/models/account_quota.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

export 'package:qnote_flutter/core/ai/account_auth_types.dart';

/// 浏览器登录句柄：弹层负责打开 [url]，等待 [result]
class RaccoonLoginHandle {
  final String url;
  final Future<AiAccount> result;
  final void Function() cancel;

  const RaccoonLoginHandle({
    required this.url,
    required this.result,
    required this.cancel,
  });
}

/// 商汤小浣熊（xiaohuanxiong.com）订阅账号的登录、刷新与模型目录
///
/// 接口来自 magpie 社区插件 `@magpie-community/opencode-raccoon-auth`：
/// - 登录：浏览器授权页 → `http://127.0.0.1:<port>/auth/callback?code=...`
///   → `POST /api/web/auth/v1/login_with_authorization_code`；
/// - 刷新：`POST /api/web/auth/v1/refresh`；
/// - 聊天：`POST /api/web/llm/v2/chat/completions`，标准 OpenAI 格式；
/// - 模型：`GET /api/web/llm/v2/model_catalog`。
///
/// 一个厂商条目可以登录多个账号：账号存在 `ai_accounts`（一账号一行），
/// 选号与亲和由 [RaccoonAccountRouter] 负责。token 不参与 WebDAV 同步与备份导出。
class RaccoonAuthService extends AccountAuthService {
  RaccoonAuthService._();

  static final RaccoonAuthService instance = RaccoonAuthService._();

  /// 厂商模板 id（`lib/config/models.dart` 与 `ai_providers.vendor_id`）
  static const String templateId = 'raccoon';

  @override
  String get vendorId => templateId;

  @override
  String get kind => AiAccount.kindRaccoon;

  @override
  String get vendorLabel => '小浣熊';

  @override
  AccountAuthRequiredException notLoggedIn(String providerId) =>
      RaccoonAuthRequiredException(providerId);

  @override
  AccountAuthRequiredException authExpired(String providerId) =>
      RaccoonAuthRequiredException(
        providerId,
        message: '小浣熊登录已失效，请重新登录',
      );

  static const String mainOrigin = 'https://xiaohuanxiong.com';
  static const String authBase = '$mainOrigin/api/web/auth/v1';
  static const String llmBase = '$mainOrigin/api/web/llm/v2';

  /// 提前多久刷新（与插件一致的 60 秒量级）
  static const Duration refreshMargin = Duration(seconds: 60);

  final AiAccountRepository _repository = AiAccountRepository.instance;

  final RaccoonAccountRouter _router = RaccoonAccountRouter.instance;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {'Accept': 'application/json'},
    ),
  );

  /// accountId → 登录态（进程内缓存；登录/刷新/退出都会更新）
  final Map<String, AiAccount> _cache = {};

  /// accountId → 正在进行的刷新（合并并发刷新，避免 refresh token 被重复消费）
  final Map<String, Future<AiAccount>> _refreshing = {};

  /// 测试注入：替换底层 HTTP adapter（不联网校验换取/刷新/目录）
  @visibleForTesting
  set httpClientAdapterForTest(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
  }

  // ── 账号读取 ─────────────────────────────────────────────

  /// 某厂商条目下的全部账号（默认走缓存；[forceReload] 用于设置页刷新）
  @override
  Future<List<AiAccount>> accountsFor(
    String providerId, {
    bool forceReload = false,
  }) async {
    final loader = accountsLoaderForTest;
    if (loader != null) {
      final accounts = await loader(providerId);
      for (final account in accounts) {
        _cache[account.id] = account;
      }
      return accounts;
    }
    if (!forceReload) {
      final cached = _cachedFor(providerId);
      if (cached.isNotEmpty) return cached;
    }
    final stored = (await _repository.getByProvider(providerId))
        .where((account) => account.kind == AiAccount.kindRaccoon)
        .toList();
    for (final account in stored) {
      _cache[account.id] = account;
    }
    return stored;
  }

  /// 测试注入：绕开数据库直接给账号列表（发信层多账号单测不搭 sqflite）
  @visibleForTesting
  static Future<List<AiAccount>> Function(String providerId)?
  accountsLoaderForTest;

  /// 某厂商下排在最前的账号（兼容旧调用：单账号场景等价于「那个账号」）
  Future<AiAccount?> sessionFor(
    String providerId, {
    bool forceReload = false,
  }) async {
    final accounts = await accountsFor(providerId, forceReload: forceReload);
    return accounts.isEmpty ? null : accounts.first;
  }

  List<AiAccount> _cachedFor(String providerId) {
    final result = _cache.values
        .where(
          (a) => a.providerId == providerId && a.kind == AiAccount.kindRaccoon,
        )
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return result;
  }

  // ── 发信前选号 ───────────────────────────────────────────

  /// 为本次请求选一个账号并取到可用 token
  ///
  /// 返回 null 表示「这个厂商还没有登录任何账号」；有账号但全部在冷却/本次都已
  /// 试过时抛 [RaccoonAuthRequiredException]（文案区分「限流冷却」与「未登录」），
  /// 避免把「所有账号都在限流」误报成「请重新登录」。
  ///
  /// [triedAccountIds] 由发信层在失败后累加，保证一次请求内不会反复回到同一个
  /// 失败账号（[AccountAffinity.strict] 除外，见 [RaccoonAccountRouter.select]）。
  @override
  Future<AccountSession?> sessionForRequest(
    String providerId, {
    String routing = AiProvider.defaultAccountRouting,
    String affinity = AiProvider.defaultAccountAffinity,
    AiRequestScope? scope,
    Set<String> triedAccountIds = const {},
    bool advance = true,
  }) async {
    // 测试注入：绕开数据库直接给 token（发信层单测不搭 sqflite）
    final loader = accessTokenLoaderForTest;
    if (loader != null) {
      final token = await loader(providerId);
      if (token == null || token.trim().isEmpty) return null;
      final now = DateTime.now();
      return AccountSession(
        account: AiAccount(
          id: 'test-account',
          providerId: providerId,
          accessToken: token,
          createdAt: now,
          updatedAt: now,
        ),
        accessToken: token,
      );
    }

    final accounts = await accountsFor(providerId);
    if (accounts.isEmpty) return null;

    final selection = _router.select(
      providerId: providerId,
      accounts: accounts,
      routing: AccountRouting.fromId(routing),
      affinity: AccountAffinity.fromId(affinity),
      scope: scope,
      triedAccountIds: triedAccountIds,
      advance: advance,
    );
    if (selection == null) {
      final enabled = accounts.where((a) => a.enabled).toList();
      if (enabled.isEmpty) {
        throw RaccoonAuthRequiredException(
          providerId,
          message: '小浣熊账号已全部停用，请到「设置 → AI 模型配置」启用一个账号',
        );
      }
      // 还有没试过的账号 → 说明它们都在冷却，是「限流」而不是「没登录」
      final untried = enabled
          .where((a) => !triedAccountIds.contains(a.id))
          .toList();
      if (untried.isNotEmpty) {
        throw RaccoonAuthRequiredException(
          providerId,
          message: '小浣熊账号都在限流冷却中，稍后重试',
        );
      }
      // 本次请求已经把能用的账号都试过了：交回调用方 rethrow 原始错误
      return null;
    }

    final token = await accessTokenForAccount(selection.account);
    if (token == null || token.trim().isEmpty) {
      // 这个账号的凭证已经废了：标记冷却，让本次请求换下一个账号
      _router.markFailed(
        selection.account,
        const RaccoonAuthRequiredException(''),
        affinity: AccountAffinity.fromId(affinity),
      );
      return null;
    }
    return AccountSession(
      account: selection.account,
      accessToken: token,
    );
  }

  /// 记一次账号成功（智能策略的成功率统计 + 解除自身冷却）
  @override
  void markAccountSucceeded(AiAccount account) =>
      _router.markSucceeded(account);

  /// 记一次账号失败（进入冷却 + 清掉亲和位置）
  @override
  void markAccountFailed(
    AiAccount account,
    Object error, {
    String affinity = AiProvider.defaultAccountAffinity,
  }) {
    _router.markFailed(
      account,
      error,
      affinity: AccountAffinity.fromId(affinity),
    );
  }

  /// 本次请求是否还有「别的账号」可以换
  ///
  /// 只做预检、不推进游标、也不取 token：发信层据此判断撞限流时应该「换号重发」
  /// 还是「单账号退避重试」。单账号厂商返回 false，行为与多账号改造前完全一致。
  @override
  Future<bool> hasAlternateAccount(
    String providerId, {
    String routing = AiProvider.defaultAccountRouting,
    String affinity = AiProvider.defaultAccountAffinity,
    AiRequestScope? scope,
    Set<String> triedAccountIds = const {},
  }) async {
    final accounts = await accountsFor(providerId);
    if (accounts.where((a) => a.enabled).length < 2) return false;
    return _router.select(
          providerId: providerId,
          accounts: accounts,
          routing: AccountRouting.fromId(routing),
          affinity: AccountAffinity.fromId(affinity),
          scope: scope,
          triedAccountIds: triedAccountIds,
          advance: false,
        ) !=
        null;
  }

  /// 按 accountId 取账号对象（发信层失败归因用）
  @override
  Future<AiAccount?> accountById(String accountId) async {
    final cached = _cache[accountId];
    if (cached != null) return cached;
    final stored = await _repository.getById(accountId);
    if (stored != null) _cache[stored.id] = stored;
    return stored;
  }

  /// 进程内已缓存的账号（同步读取，发信成功路径上用，避免多一次读库）
  @override
  AiAccount? accountFromCache(String accountId) => _cache[accountId];

  /// 账号是否在冷却中（界面展示「限流中」用）
  @override
  bool isAccountCooling(String accountId) => _router.isCooling(accountId);

  // ── token 读取与刷新 ─────────────────────────────────────

  /// 取某个账号的 access token：临近过期会先刷新
  ///
  /// 返回 null 表示这个账号当前不可用（无 refresh token 且已过期、或刷新被拒）。
  @override
  Future<String?> accessTokenForAccount(AiAccount account) async {
    final loader = accessTokenLoaderForTest;
    if (loader != null) return loader(account.providerId);

    // 账号列表来自测试注入时不要去读库：那个账号对象就是唯一事实
    final current = accountsLoaderForTest != null
        ? account
        : await _refreshCacheFromStore(account);
    if (current.accessToken.trim().isEmpty) return null;
    final needsRefresh =
        current.isExpired || current.isStale(margin: refreshMargin);
    if (!needsRefresh) return current.accessToken;
    try {
      final refreshed = await refreshAccount(current.id, force: true);
      return refreshed.accessToken;
    } on RaccoonAuthRequiredException {
      // 只有厂商明确拒绝（4xx / 没有 refresh token）才标记失效；
      // 网络抖动不能把用户踢下线
      await _markExpired(current.id);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 兼容旧调用：按 providerId 取「排在最前的账号」的 token
  Future<String?> accessTokenFor(String providerId) async {
    final account = await sessionFor(providerId);
    if (account == null) return null;
    return accessTokenForAccount(account);
  }

  /// 测试注入：绕开数据库直接返回 token（仅发信层单测用）
  @visibleForTesting
  static Future<String?> Function(String providerId)? accessTokenLoaderForTest;

  /// 测试注入：登录落库（默认写 `ai_accounts` 表）；注入后纯内存，不碰 sqflite
  @visibleForTesting
  static Future<void> Function(AiAccount account)? accountSaverForTest;

  /// 测试注入：替换换取授权失败后的退避等待（默认 400ms → 1200ms）
  @visibleForTesting
  static Future<void> Function(int attempt)? exchangeRetryWaitForTest;

  /// 测试注入：额度接口 401 后刷新账号（默认走 `refreshAccount`）
  @visibleForTesting
  static Future<AiAccount> Function(AiAccount account)? accountRefresherForTest;

  /// 发信前取 token 的严格版本：没有可用登录态直接抛给上层提示
  Future<String> requireAccessToken(String providerId) async {
    final token = await accessTokenFor(providerId);
    if (token == null || token.trim().isEmpty) {
      throw RaccoonAuthRequiredException(providerId);
    }
    return token;
  }

  /// 刷新某个账号的 access token（[force] 为 false 时仍新鲜则直接返回缓存）
  @override
  Future<AiAccount> refreshAccount(String accountId, {bool force = false}) {
    final running = _refreshing[accountId];
    if (running != null) return running;
    final future = _refresh(accountId, force: force).whenComplete(() {
      _refreshing.remove(accountId);
    });
    _refreshing[accountId] = future;
    return future;
  }

  /// 兼容旧调用：刷新某厂商下排在最前的账号
  @override
  Future<AiAccount> refresh(String providerId, {bool force = false}) async {
    final account = await sessionFor(providerId, forceReload: true);
    if (account == null) throw RaccoonAuthRequiredException(providerId);
    return refreshAccount(account.id, force: force);
  }

  Future<AiAccount> _refresh(String accountId, {required bool force}) async {
    final stored = await _repository.getById(accountId);
    if (stored == null) {
      _cache.remove(accountId);
      throw const RaccoonAuthRequiredException('', message: '账号已删除，请重新登录');
    }
    _cache[accountId] = stored;
    if (!force && !stored.isStale(margin: refreshMargin) && !stored.isExpired) {
      return stored;
    }
    final refreshToken = stored.refreshToken.trim();
    if (refreshToken.isEmpty) {
      await _markExpired(accountId);
      throw RaccoonAuthRequiredException(
        stored.providerId,
        message: '小浣熊登录已过期，请重新登录',
      );
    }

    try {
      final response = await _dio.post<dynamic>(
        '$authBase/refresh',
        data: {'refresh_token': refreshToken},
      );
      final access = _tokenFromResponse(response.data, 'access_token');
      final nextRefresh =
          _tokenFromResponse(response.data, 'refresh_token') ?? refreshToken;
      if (access == null || access.isEmpty) {
        throw const FormatException('刷新未返回 access_token');
      }
      final next = await _accountFromTokens(
        stored.providerId,
        accountId: stored.id,
        access: access,
        refresh: nextRefresh,
        previous: stored,
        fetchProfile: true,
      );
      await _save(next);
      LoggerService.instance.logAI(
        '小浣熊登录态已刷新: ${next.label}',
        details: '有效期至 ${next.expiresAt?.toIso8601String() ?? '未知'}',
      );
      return next;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      LoggerService.instance.logAI(
        '小浣熊刷新登录态失败: HTTP $status',
        level: LogLevel.warning,
        details: '${e.response?.data ?? e.message}',
      );
      if (status != null && status >= 400 && status < 500) {
        await _markExpired(accountId);
        throw RaccoonAuthRequiredException(
          stored.providerId,
          message: '小浣熊登录已失效，请重新登录',
        );
      }
      rethrow;
    }
  }

  // ── 登录 ─────────────────────────────────────────────────

  /// 浏览器回环登录：返回句柄，由弹层打开 [RaccoonLoginHandle.url]
  ///
  /// [accountId] 为空表示「新增一个账号」；不为空表示「重新登录这个账号」
  /// （保留原来的备注与轮换顺序）。
  Future<RaccoonLoginHandle> startBrowserLogin(
    String providerId, {
    String? accountId,
  }) async {
    AiAccount? account;
    final loopback = await startRaccoonLoopbackLogin(
      // 换取放进回环请求里：失败时浏览器页面直接显示「登录未完成」，
      // 不会出现网页提示成功、App 里却报错的错位
      onCode: (code) async {
        account = await exchangeCode(providerId, code, accountId: accountId);
      },
    );
    final result = loopback.code.then((_) {
      final signedIn = account;
      if (signedIn == null) {
        throw const FormatException('登录失败：未获取登录凭证');
      }
      return signedIn;
    });
    return RaccoonLoginHandle(
      url: loopback.url,
      result: result,
      cancel: loopback.cancel,
    );
  }

  /// 授权码换 token
  ///
  /// 浏览器回环登录里授权码是「刚签发就交换」：厂商后端偶发还没把这条码同步到
  /// 兑换节点，第一次会以 `200035` 或空的 2xx 拒绝，隔一两秒用同一个码再换就能
  /// 成功——现象就是网页登录报错、把同一个回调链接复制出来粘贴反而能登录。
  /// 因此这里对「可能还没生效」的失败做两次短退避重试；确定性拒绝立即抛出。
  Future<AiAccount> exchangeCode(
    String providerId,
    String code, {
    String? accountId,
  }) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('授权码为空');
    }
    final tokens = await _exchangeTokens(trimmed);
    return _persistLogin(
      providerId,
      access: tokens.access,
      refresh: tokens.refresh,
      accountId: accountId,
    );
  }

  /// 换取 access/refresh token（含重试）
  ///
  /// 落库放在重试之外：授权码一次性，重试只会重复交换，不该把库写入错误一起重来。
  Future<({String access, String refresh})> _exchangeTokens(String code) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        final wait = exchangeRetryWaitForTest;
        if (wait != null) {
          await wait(attempt);
        } else {
          // 400ms → 1200ms：给厂商侧授权码入库留时间，又不太拖慢失败提示
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 1 ? 400 : 1200),
          );
        }
      }
      try {
        return await _exchangeTokensOnce(code);
      } on _ExchangeFailure catch (failure) {
        lastError = failure.error;
        LoggerService.instance.logAI(
          '小浣熊换取登录凭证失败（第 ${attempt + 1} 次）',
          level: LogLevel.warning,
          details: failure.detail,
        );
        if (!failure.retryable) throw failure.error;
      }
    }
    throw lastError ?? const FormatException('登录失败：未获取登录凭证');
  }

  Future<({String access, String refresh})> _exchangeTokensOnce(
    String code,
  ) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        '$authBase/login_with_authorization_code',
        data: {'authorization_code': code},
      );
    } on DioException catch (e) {
      final payload = e.response?.data;
      final status = e.response?.statusCode;
      final vendorCode = _vendorCode(payload);
      if (vendorCode == '200035') {
        throw _ExchangeFailure(
          const FormatException('授权码已失效，请重新发起网页登录'),
          retryable: true,
          detail: 'HTTP ${status ?? '-'} code=200035',
        );
      }
      throw _ExchangeFailure(
        FormatException(
          _vendorError(payload, '登录失败：HTTP ${status ?? '网络异常'}'),
        ),
        // 5xx / 429 / 超时 / 连接中断都可能是瞬时抖动；其余 4xx 是确定性拒绝
        retryable:
            status == null || status >= 500 || status == 429 || status == 408,
        detail:
            'HTTP ${status ?? '-'} code=${vendorCode ?? '-'} '
            '${_vendorError(payload, _preview(payload))}',
      );
    }

    final payload = response.data;
    final access = _tokenFromResponse(payload, 'access_token');
    final refresh = _tokenFromResponse(payload, 'refresh_token');
    final vendorCode = _vendorCode(payload);
    if (vendorCode == '200035') {
      // 有的网关把业务错误包成 2xx：同样按「授权码已失效」处理并重试
      throw _ExchangeFailure(
        const FormatException('授权码已失效，请重新发起网页登录'),
        retryable: true,
        detail: 'HTTP ${response.statusCode} code=200035',
      );
    }
    if (access == null || access.isEmpty || refresh == null) {
      throw _ExchangeFailure(
        FormatException(
          _vendorError(payload, '登录失败：HTTP ${response.statusCode}'),
        ),
        retryable: true,
        detail:
            'HTTP ${response.statusCode} code=${vendorCode ?? '-'} '
            '响应缺少 access_token/refresh_token: ${_preview(payload)}',
      );
    }
    return (access: access, refresh: refresh);
  }

  /// 手动兜底：粘贴完整回调链接、JWT，或 `{"access_token":...,"refresh_token":...}`
  Future<AiAccount> loginWithPastedInput(
    String providerId,
    String raw, {
    String? accountId,
  }) async {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('请粘贴回调链接或 Token');
    }

    // JSON token pair
    if (text.startsWith('{')) {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('JSON 格式错误');
      }
      final access = (decoded['access_token'] ?? decoded['accessToken'])
          ?.toString()
          .trim();
      final refresh = (decoded['refresh_token'] ?? decoded['refreshToken'])
          ?.toString()
          .trim();
      if (access == null || access.isEmpty) {
        throw const FormatException('JSON 缺少 access_token');
      }
      return _persistLogin(
        providerId,
        access: _stripBearer(access),
        refresh: refresh ?? '',
        accountId: accountId,
      );
    }

    // 裸 JWT（没有 refresh token，到期后需要重新登录）
    if (text.split('.').length == 3 && !text.contains('://')) {
      return _persistLogin(
        providerId,
        access: _stripBearer(text),
        refresh: '',
        accountId: accountId,
      );
    }

    // 回调链接：office-raccoon://auth/callback?code=... 或 http://127.0.0.1/...
    final uri = Uri.tryParse(text);
    if (uri == null) {
      throw const FormatException('回调链接或 Token 无效');
    }
    final code = uri.queryParameters['code']?.trim() ?? '';
    if (code.isEmpty) {
      throw const FormatException('回调链接缺少授权码 code');
    }
    return exchangeCode(providerId, code, accountId: accountId);
  }

  /// 落库一个登录态：同一厂商账号重复登录时覆盖旧行，新账号追加到末尾
  Future<AiAccount> _persistLogin(
    String providerId, {
    required String access,
    required String refresh,
    String? accountId,
  }) async {
    final existing = await accountsFor(providerId, forceReload: true);
    final target = accountId == null
        ? null
        : existing.where((a) => a.id == accountId).firstOrNull;

    // 先按 uid/手机号判断是不是「已经登录过的同一个账号」：是则更新那一行，
    // 否则同一账号会在列表里堆出多行，轮换时反复打到同一个账号上
    AiAccount? previous = target;
    if (previous == null) {
      // 探测只解析 JWT 里的 uid/手机号归属，不必为去重多打一次 user_info
      final probe = await _accountFromTokens(
        providerId,
        accountId: '',
        access: access,
        refresh: refresh,
      );
      for (final account in existing) {
        if (account.isSameVendorAccount(probe)) {
          previous = account;
          break;
        }
      }
    }

    final account = await _accountFromTokens(
      providerId,
      accountId: previous?.id ?? const Uuid().v4(),
      access: access,
      refresh: refresh,
      previous: previous,
      fetchProfile: true,
    );
    final next = previous == null
        ? account.copyWith(sortOrder: _nextSortOrder(existing))
        : account;
    await _save(next);
    LoggerService.instance.logAI(
      previous == null ? '小浣熊新增账号: ${next.label}' : '小浣熊账号已更新: ${next.label}',
    );
    return next;
  }

  int _nextSortOrder(List<AiAccount> existing) {
    if (existing.isEmpty) return 0;
    return existing.map((a) => a.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
  }

  // ── 账号管理 ─────────────────────────────────────────────

  /// 退出单个账号（删掉这一行登录态）
  @override
  Future<void> logout(String accountId) async {
    _cache.remove(accountId);
    _router.forget(accountId);
    await _repository.delete(accountId);
  }

  /// 退出某厂商下的全部账号（删除厂商 / 切回 API Key 模式）
  @override
  Future<void> logoutProvider(String providerId) async {
    final accounts = await accountsFor(providerId, forceReload: true);
    for (final account in accounts) {
      _cache.remove(account.id);
    }
    _router.resetProvider(providerId, accounts: accounts);
    await _repository.deleteByProvider(providerId);
  }

  /// 修改账号备注 / 启用开关 / 顺序
  @override
  Future<AiAccount> updateAccount(
    AiAccount account, {
    String? alias,
    bool? enabled,
  }) async {
    final next = account.copyWith(alias: alias, enabled: enabled);
    await _save(next);
    return next;
  }

  /// 重排账号顺序（「顺序」策略的优先级即此顺序）
  @override
  Future<List<AiAccount>> reorderAccounts(
    String providerId,
    List<String> orderedIds,
  ) async {
    final accounts = await accountsFor(providerId, forceReload: true);
    final byId = {for (final a in accounts) a.id: a};
    final next = <AiAccount>[];
    var index = 0;
    for (final id in orderedIds) {
      final account = byId.remove(id);
      if (account == null) continue;
      next.add(account.copyWith(sortOrder: index++));
    }
    // 没出现在 orderedIds 里的账号（理论上不该有）排到末尾，避免丢失
    for (final account in byId.values) {
      next.add(account.copyWith(sortOrder: index++));
    }
    await _repository.upsertAll(next);
    for (final account in next) {
      _cache[account.id] = account;
    }
    return next;
  }

  /// 数据管理页清空全部数据后清掉进程内缓存
  ///
  /// 选号游标、亲和记忆与冷却表也要一起清：它们指向的账号已经不存在了。
  @override
  void clearCache() {
    _cache.clear();
    RaccoonAccountRouter.instance.clearAll();
  }

  // ── 模型目录 ─────────────────────────────────────────────

  /// 拉取模型目录（[token] 为空时用匿名请求，部分账号的目录是公开的）
  Future<List<AiProviderModel>> fetchModels({String? token}) async {
    try {
      final response = await _dio.get<dynamic>(
        '$llmBase/model_catalog',
        options: Options(
          headers: {
            if (token != null && token.trim().isNotEmpty)
              'Authorization': 'Bearer ${_stripBearer(token)}',
          },
        ),
      );
      final models = _modelsFromCatalog(response.data);
      if (models.isEmpty) {
        throw const FormatException('模型目录为空');
      }
      return models;
    } on DioException catch (e) {
      throw FormatException(
        _vendorError(
          e.response?.data,
          '获取模型目录失败（HTTP ${e.response?.statusCode}）',
        ),
      );
    }
  }

  /// 带登录态的模型目录：401 时刷新一次再试
  @override
  Future<List<AiProviderModel>> fetchModelsForProvider(
    String providerId,
  ) async {
    // 挑第一个「启用且未过期」的账号：排在最前的那个可能已经被停用或登录失效，
    // 拿它去扫目录只会得到一次必然失败的 401
    final accounts = await accountsFor(providerId, forceReload: true);
    final candidates = [
      ...accounts.where((a) => a.enabled && !a.isExpired),
      ...accounts.where((a) => !a.enabled || a.isExpired),
    ];
    if (candidates.isEmpty) throw RaccoonAuthRequiredException(providerId);
    for (final account in candidates) {
      final token = await accessTokenForAccount(account);
      if (token == null) continue;
      try {
        return await fetchModels(token: token);
      } on FormatException {
        // 目录接口的 401 会以 FormatException 抛出：刷新一次再试
        try {
          final refreshed = await refreshAccount(account.id, force: true);
          return fetchModels(token: refreshed.accessToken);
        } catch (_) {
          continue;
        }
      }
    }
    throw RaccoonAuthRequiredException(providerId);
  }

  // ── 账号额度 ─────────────────────────────────────────────

  /// 查询单个账号的当前积分与套餐（只返回结果，缓存交给界面）
  ///
  /// 余额接口 `/points/v1/balance` 对网页端也可能返回 403（厂商侧限制），此时
  /// 回落到客户端开屏调用的 `/office/v3/setting_info`，两处都是 `available_points`。
  /// 服务端不认 token（401 / 200001 / 200003）时强制刷新一次再试，仍被拒才标记
  /// 账号过期——与发信层的 401 处理口径一致，不把「额度查不到」当成「登录失效」。
  @override
  Future<AccountQuota> fetchQuota(AiAccount account) =>
      _runWithToken(account, _readQuota);

  /// 带登录态执行一次只读接口：被服务端拒绝时刷新一次再试，仍被拒才标记过期
  ///
  /// 与发信层的 401 处理口径一致——不把「接口查不到」当成「登录失效」。
  Future<T> _runWithToken<T>(
    AiAccount account,
    Future<T> Function(String token) run,
  ) async {
    final token = await accessTokenForAccount(account);
    if (token == null || token.trim().isEmpty) {
      throw RaccoonAuthRequiredException(account.providerId);
    }
    try {
      return await run(token);
    } on _QuotaAuthRejected {
      final refresher = accountRefresherForTest;
      final AiAccount refreshed;
      try {
        refreshed = refresher != null
            ? await refresher(account)
            : await refreshAccount(account.id, force: true);
      } on RaccoonAuthRequiredException {
        rethrow;
      }
      try {
        return await run(refreshed.accessToken);
      } on _QuotaAuthRejected {
        await _markExpiredAccount(refreshed);
        throw RaccoonAuthRequiredException(
          account.providerId,
          message: '小浣熊登录已失效，请重新登录',
        );
      }
    }
  }

  Future<AccountQuota> _readQuota(String token) async {
    int? available;
    Object? balanceError;
    try {
      available = _pointsOf(
        await _quotaGet('/api/web/points/v1/balance', token),
      );
    } on _QuotaAuthRejected {
      rethrow;
    } catch (e) {
      // 403 等拒绝不是登录失效：留到下面回落 setting_info
      balanceError = e;
    }
    if (available == null) {
      try {
        available = _pointsOf(
          await _quotaGet('/api/web/office/v3/setting_info', token),
        );
      } on _QuotaAuthRejected {
        rethrow;
      } catch (e) {
        // 两处都失败时优先报余额接口的错误：它才是积分的主口径
        throw balanceError is FormatException ? balanceError : e;
      }
    }
    if (available == null) {
      throw balanceError is FormatException
          ? balanceError
          : const FormatException('未返回积分');
    }

    // 套餐只影响展示，读不到就留空（不把未知当成 Free）
    var plan = '';
    DateTime? planExpiresAt;
    try {
      final parsed = _planOf(
        await _quotaGet('/api/web/auth/v1/entitlement_info', token),
      );
      plan = parsed.plan;
      planExpiresAt = parsed.expiresAt;
    } catch (_) {}
    return AccountQuota(
      balance: available,
      plan: plan,
      planExpiresAt: planExpiresAt,
      fetchedAt: DateTime.now(),
    );
  }

  // ── 手动签到 ─────────────────────────────────────────────

  /// 账单列表：签到前后各拍一次，用差额确认到底到账多少积分
  static const String _billsPath =
      '/api/web/points/v1/bills?paging.limit=20&paging.offset=0';

  /// 手动签到并领取当日积分（只做用户点击触发，不自动执行）
  ///
  /// 厂商没有独立的签到接口——开屏接口 `/office/v3/setting_info` 本身就是
  /// 签到触发器（与 magpie 插件一致）。为了避免重复点击把历史账单误报成
  /// 新到账，先拍一张「今天已有发放账单」的快照，签到后再对比账单差异；
  /// 快照失败时退化成「接口成功就算已处理」，宁可少报也不虚报积分。
  @override
  Future<AccountCheckInResult> checkIn(AiAccount account) =>
      _runWithToken(account, _checkInWithToken);

  Future<AccountCheckInResult> _checkInWithToken(String token) async {
    final today = _beijingDateKey(DateTime.now());
    Set<String>? beforeKeys;
    try {
      beforeKeys = _checkinGrantKeys(await _quotaGet(_billsPath, token), today);
    } catch (_) {
      // 快照只影响「能不能算出本次到账」，不能挡住签到本身
    }

    // 带桌面端请求头才会触发当日积分发放（与插件同口径）
    await _quotaGet(
      '/api/web/office/v3/setting_info',
      token,
      headers: {
        'X-Client-Platform': defaultTargetPlatform == TargetPlatform.macOS
            ? 'desktop-mac'
            : 'desktop-windows',
        'X-Client-Version': 'v1.0.0',
        'X-Raccoon-Language': 'zh',
      },
    );

    final checkedAt = DateTime.now();
    if (beforeKeys == null) {
      // 没有签到前的账单快照：无法判断是否新到账，按「已签到」收尾
      return AccountCheckInResult(
        claimed: false,
        credit: 0,
        message: '今日已签到',
        checkedAt: checkedAt,
      );
    }

    final bills = await _quotaGet(_billsPath, token);
    var credit = 0;
    final names = <String>[];
    for (final item in _billItems(bills)) {
      if (!_isCheckinGrantBill(item, today)) continue;
      if (beforeKeys.contains(_billKey(item))) continue;
      credit += _intOf(item['points']);
      final name = (item['event_name'] ?? '').toString().trim();
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    if (credit <= 0) {
      return AccountCheckInResult(
        claimed: false,
        credit: 0,
        message: '今日已签到',
        checkedAt: checkedAt,
      );
    }
    return AccountCheckInResult(
      claimed: true,
      credit: credit,
      message: '${names.isEmpty ? '今日签到' : names.join(' + ')} +$credit',
      checkedAt: checkedAt,
    );
  }

  /// 账单里「今天已发放的签到类积分」的键集合（用于签到前后对比）
  static Set<String> _checkinGrantKeys(dynamic payload, String today) {
    final keys = <String>{};
    for (final item in _billItems(payload)) {
      if (_isCheckinGrantBill(item, today)) keys.add(_billKey(item));
    }
    return keys;
  }

  static List<Map> _billItems(dynamic payload) {
    if (payload is! Map) return const [];
    final items = payload['items'];
    if (items is! List) return const [];
    return items.whereType<Map>().toList();
  }

  /// 只认当天到账的发放账单：`daily_grant`（每日签到）、`reward_grant`
  /// （奖励发放），`biz_type` 缺失时也当成发放记录（兼容旧版接口）
  static bool _isCheckinGrantBill(Map item, String today) {
    if (_intOf(item['points']) <= 0) return false;
    if (_vendorDateKey(item['created_at']) != today) return false;
    final bizType = (item['biz_type'] ?? '').toString().trim();
    return bizType.isEmpty ||
        bizType == 'daily_grant' ||
        bizType == 'reward_grant';
  }

  /// 账单键：优先用厂商 id，缺失时用「时间 + 积分 + 事件名」兜底
  static String _billKey(Map item) {
    final id = (item['bill_id'] ?? item['biz_id'] ?? '').toString().trim();
    if (id.isNotEmpty) return id;
    return '${item['created_at'] ?? ''}:'
        '${item['points'] ?? ''}:${item['event_name'] ?? ''}';
  }

  static int _intOf(dynamic raw) {
    final number = num.tryParse(raw?.toString().trim() ?? '');
    if (number == null || !number.isFinite) return 0;
    return number.floor();
  }

  /// 厂商口径的「今天」按北京时间算
  static String _beijingDateKey(DateTime now) {
    final beijing = now.toUtc().add(const Duration(hours: 8));
    String two(int value) => value.toString().padLeft(2, '0');
    return '${beijing.year.toString().padLeft(4, '0')}-'
        '${two(beijing.month)}-${two(beijing.day)}';
  }

  /// 账单时间可能是北京时间字符串、带时区的 ISO 或时间戳
  static String _vendorDateKey(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return '';
    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      return text.length >= 10 ? text.substring(0, 10) : '';
    }
    // 带 Z / 偏移量的值解析出来是 UTC：换算成北京时间再取日期
    if (parsed.isUtc) return _beijingDateKey(parsed);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${parsed.year.toString().padLeft(4, '0')}-'
        '${two(parsed.month)}-${two(parsed.day)}';
  }

  /// GET 小浣熊网页接口并拆掉 `{code, data}` 信封
  ///
  /// 401 / `code=200001|200003` 表示「登录态不被接受」，交给调用方决定刷新重试；
  /// 其余非零 code 统一转成带厂商文案的 FormatException。
  Future<dynamic> _quotaGet(
    String path,
    String token, {
    Map<String, String>? headers,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        '$mainOrigin$path',
        options: Options(
          headers: {
            'Authorization': 'Bearer ${_stripBearer(token)}',
            ...?headers,
          },
        ),
      );
    } on DioException catch (e) {
      final payload = e.response?.data;
      final code = _vendorCode(payload);
      if (e.response?.statusCode == 401 ||
          code == '200001' ||
          code == '200003') {
        throw const _QuotaAuthRejected();
      }
      throw FormatException(
        _vendorError(payload, '查询积分失败（HTTP ${e.response?.statusCode}）'),
      );
    }
    final payload = response.data;
    final code = _vendorCode(payload);
    if (code == '200001' || code == '200003') {
      throw const _QuotaAuthRejected();
    }
    if (code != null && code != '0') {
      throw FormatException(_vendorError(payload, '查询积分失败（code=$code）'));
    }
    if (payload is Map && payload['data'] != null) return payload['data'];
    return payload;
  }

  static int? _pointsOf(dynamic payload) {
    if (payload is! Map) return null;
    final value = payload['available_points'];
    if (value == null) return null;
    final number = num.tryParse(value.toString().trim());
    if (number == null || !number.isFinite) return null;
    return number.floor();
  }

  static ({String plan, DateTime? expiresAt}) _planOf(dynamic payload) {
    if (payload is! Map) return (plan: '', expiresAt: null);
    final office = payload['office'] is Map
        ? payload['office'] as Map
        : const {};
    final codeBlock = payload['code'] is Map
        ? payload['code'] as Map
        : const {};
    final proEnable =
        office['pro_enable'] == true || codeBlock['pro_enable'] == true;
    final planType = office['active_plan'] is Map
        ? (office['active_plan'] as Map)['type']
        : office['plan_type'];
    final type = planType?.toString().trim() ?? '';
    final plan = proEnable
        ? (type.isEmpty || type == 'none' ? 'Pro' : type)
        : 'Free';
    final rawExpire =
        office['pro_expired_time'] ??
        (office['active_plan'] is Map
            ? (office['active_plan'] as Map)['subscription_expired_at']
            : null);
    return (
      plan: plan,
      // 与插件一致：只有付费套餐才展示到期时间，Free 不跟着一个历史时间跑
      expiresAt: proEnable ? _parseVendorTime(rawExpire) : null,
    );
  }

  /// 厂商时间字段可能是 ISO 字符串、毫秒或秒级时间戳
  static DateTime? _parseVendorTime(dynamic raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return parsed;
    final number = int.tryParse(text);
    if (number == null || number <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      number > 100000000000 ? number : number * 1000,
    );
  }

  Future<void> _markExpiredAccount(AiAccount account) async {
    await _save(
      account.copyWith(
        status: AiAccount.statusExpired,
        updatedAt: DateTime.now(),
      ),
    );
  }

  // ── 内部 ─────────────────────────────────────────────────

  Future<void> _save(AiAccount account) async {
    final saver = accountSaverForTest;
    if (saver != null) {
      await saver(account);
      _cache[account.id] = account;
      return;
    }
    await _repository.upsert(account);
    _cache[account.id] = account;
  }

  /// 缓存里的那份可能已被其他入口刷新过，优先读库里的最新值
  Future<AiAccount> _refreshCacheFromStore(AiAccount account) async {
    final stored = await _repository.getById(account.id);
    if (stored == null) return account;
    _cache[stored.id] = stored;
    return stored;
  }

  Future<void> _markExpired(String accountId) async {
    final stored = await _repository.getById(accountId);
    if (stored == null) return;
    final next = stored.copyWith(
      status: AiAccount.statusExpired,
      updatedAt: DateTime.now(),
    );
    await _save(next);
  }

  Future<AiAccount> _accountFromTokens(
    String providerId, {
    required String accountId,
    required String access,
    required String refresh,
    AiAccount? previous,
    bool fetchProfile = false,
  }) async {
    final cleanAccess = _stripBearer(access);
    final claims = _decodeJwtClaims(cleanAccess);
    final now = DateTime.now();
    var phone = previous?.phone ?? '';
    if (fetchProfile) {
      final fetched = await _fetchPhone(cleanAccess);
      if (fetched.isNotEmpty) phone = fetched;
    }
    return AiAccount(
      id: accountId,
      providerId: providerId,
      kind: AiAccount.kindRaccoon,
      alias: previous?.alias ?? '',
      accessToken: cleanAccess,
      refreshToken: refresh.trim(),
      expiresAt: _jwtExpiry(claims),
      uid: _extractUid(claims),
      displayName: _extractName(claims),
      phone: phone,
      status: AiAccount.statusActive,
      enabled: previous?.enabled ?? true,
      sortOrder: previous?.sortOrder ?? 0,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
  }

  /// 账号手机号（脱敏）：best effort，失败不影响登录
  Future<String> _fetchPhone(String access) async {
    try {
      final response = await _dio.get<dynamic>(
        '$authBase/user_info',
        options: Options(
          headers: {'Authorization': 'Bearer $access'},
          // 手机号只是卡片展示的加分项，不能拖慢登录/刷新
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final data = response.data;
      if (data is Map) {
        final inner = data['data'];
        if (inner is Map) {
          return _maskPhone(inner['phone']?.toString() ?? '');
        }
        return _maskPhone(data['phone']?.toString() ?? '');
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  static String? _tokenFromResponse(dynamic payload, String key) {
    if (payload is! Map) return null;
    final data = payload['data'] is Map ? payload['data'] as Map : payload;
    final value = data[key]?.toString().trim();
    if (value == null || value.isEmpty) return null;
    return _stripBearer(value);
  }

  static String _stripBearer(String value) {
    final trimmed = value.trim();
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      return trimmed.substring(7).trim();
    }
    return trimmed;
  }

  static String? _vendorCode(dynamic payload) {
    if (payload is! Map) return null;
    final value = payload['code'];
    if (value == null) return null;
    return value.toString();
  }

  /// 日志里只留一小段响应，避免整页 HTML 把 AI 日志撑爆
  static String _preview(dynamic payload, {int max = 500}) {
    final text = payload?.toString() ?? '';
    if (text.length <= max) return text;
    return '${text.substring(0, max)}…';
  }

  static String _vendorError(dynamic payload, String fallback) {
    if (payload is Map) {
      for (final key in ['details', 'message', 'msg']) {
        final value = payload[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
      final error = payload['error'];
      if (error is Map) {
        final message = error['message']?.toString().trim();
        if (message != null && message.isNotEmpty) return message;
      }
    }
    return fallback;
  }

  static List<AiProviderModel> _modelsFromCatalog(dynamic payload) {
    final root = payload is Map && payload['data'] is Map
        ? payload['data'] as Map
        : payload;
    if (root is! Map) return const [];
    final categories = root['categories'];
    final result = <AiProviderModel>[];
    final seen = <String>{};
    if (categories is List) {
      for (final category in categories) {
        if (category is! Map) continue;
        final models = category['models'];
        if (models is! List) continue;
        for (final entry in models) {
          if (entry is! Map) continue;
          final id = (entry['name'] ?? entry['model_name'])?.toString().trim();
          if (id == null || id.isEmpty || !seen.add(id)) continue;
          final rawName = (entry['display_name'] ?? entry['description'])
              ?.toString()
              .trim();
          final name =
              (rawName != null && rawName.isNotEmpty && rawName.length <= 64)
              ? rawName
              : id;
          result.add(
            AiProviderModel.of(
              id,
              name: name,
              rate: _catalogRate(entry),
              rateWas: _catalogRateWas(entry),
              contextWindow: _catalogContext(entry),
              rateNote: _catalogRateNote(entry),
              supportsVision: _catalogVision(entry),
              supportsImageGeneration: imageGenerationFromCatalogEntry(entry),
            ),
          );
        }
      }
    }
    // 目录没列默认模型时补上，避免启用列表为空
    if (seen.add('raccoon-chat-ml-5-5')) {
      result.add(
        AiProviderModel.of(
          'raccoon-chat-ml-5-5',
          name: 'Raccoon Chat (默认)',
          rate: 1,
          contextWindow: 180000,
          supportsVision: false,
        ),
      );
    }
    return result;
  }

  /// 目录里的实际生效倍率：优先限时折扣价，其次原价
  ///
  /// 倍率是选模型的主要依据（0 = 当前免费），所以宁可取到一个值也不省略：
  /// 厂商只给 `billing_multiplier` 时就用它。
  static num? _catalogRate(Map<dynamic, dynamic> entry) =>
      _numOrNull(entry['billing_effective_multiplier']) ??
      _numOrNull(entry['billing_multiplier']);

  /// 折扣前的原倍率：只有确实降价了才返回，用于展示「原 0.5×」
  static num? _catalogRateWas(Map<dynamic, dynamic> entry) {
    final base = _numOrNull(entry['billing_multiplier']);
    final effective = _numOrNull(entry['billing_effective_multiplier']);
    if (base == null || effective == null || effective >= base) return null;
    return base;
  }

  /// 厂商给的计费说明（如「限免至11月30日」）
  static String? _catalogRateNote(Map<dynamic, dynamic> entry) {
    final note = entry['billing_status_note']?.toString().trim();
    return note == null || note.isEmpty ? null : note;
  }

  /// 上下文窗口：目录把参数放在 `params` 里，个别版本提到顶层
  static int? _catalogContext(Map<dynamic, dynamic> entry) {
    final params = entry['params'];
    final fromParams = params is Map
        ? (params['context_window'] ?? params['contextWindow'])
        : null;
    return _numOrNull(fromParams ?? entry['context_window'])?.floor();
  }

  /// tags 里声明了视觉能力才算支持识图（没声明的一律返回 null，不猜）
  static bool? _catalogVision(Map<dynamic, dynamic> entry) {
    final tags = entry['tags'];
    if (tags is! List) return null;
    return tags
        .map((tag) => tag.toString().trim().toLowerCase())
        .any((tag) => tag == 'vision' || tag == 'image' || tag == 'image-understanding');
  }

  static num? _numOrNull(dynamic raw) {
    if (raw is num) return raw;
    return num.tryParse(raw?.toString().trim() ?? '');
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

  static DateTime? _jwtExpiry(Map<String, dynamic>? claims) {
    final exp = claims?['exp'];
    final seconds = exp is num ? exp.toInt() : int.tryParse('${exp ?? ''}');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  static String _extractUid(Map<String, dynamic>? claims) {
    if (claims == null) return '';
    for (final key in ['sid', 'iss']) {
      final decimal = _hexToDecimal(claims[key]?.toString() ?? '');
      if (decimal.isNotEmpty) return decimal;
    }
    for (final key in ['sub', 'id', 'user_id']) {
      final value = claims[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _extractName(Map<String, dynamic>? claims) =>
      claims?['name']?.toString().trim() ?? '';

  static String _hexToDecimal(String value) {
    final raw = value.trim().replaceFirst(
      RegExp(r'^0x', caseSensitive: false),
      '',
    );
    if (raw.isEmpty || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(raw)) return '';
    try {
      return BigInt.parse(raw, radix: 16).toString();
    } catch (_) {
      return '';
    }
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

  // ── 测试用纯函数入口（不触库、不联网） ──────────────────

  @visibleForTesting
  static Map<String, dynamic>? decodeJwtForTest(String token) =>
      _decodeJwtClaims(_stripBearer(token));

  @visibleForTesting
  static DateTime? jwtExpiryForTest(String token) =>
      _jwtExpiry(_decodeJwtClaims(_stripBearer(token)));

  @visibleForTesting
  static String extractUidForTest(String token) =>
      _extractUid(_decodeJwtClaims(_stripBearer(token)));

  @visibleForTesting
  static List<AiProviderModel> modelsFromCatalogForTest(dynamic payload) =>
      _modelsFromCatalog(payload);

  @visibleForTesting
  static String maskPhoneForTest(String raw) => _maskPhone(raw);

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _refreshing.clear();
    accessTokenLoaderForTest = null;
    accountsLoaderForTest = null;
    accountSaverForTest = null;
    exchangeRetryWaitForTest = null;
    accountRefresherForTest = null;
    RaccoonAccountRouter.instance.clearAll();
  }
}

/// 额度接口拒绝当前 token（401 / 200001 / 200003）：需要刷新登录态后重试
class _QuotaAuthRejected implements Exception {
  const _QuotaAuthRejected();
}

/// 一次换取授权的失败：区分「可能瞬时/尚未生效，可重试」与确定性拒绝
class _ExchangeFailure implements Exception {
  final Object error;
  final bool retryable;
  final String detail;

  const _ExchangeFailure(
    this.error, {
    required this.retryable,
    required this.detail,
  });
}
