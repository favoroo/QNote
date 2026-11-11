import 'dart:async';

import 'package:flutter/foundation.dart' show protected;

import 'package:qnote_flutter/core/ai/account_auth_types.dart';
import 'package:qnote_flutter/core/ai/raccoon_account_router.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:uuid/uuid.dart';

/// 额度/签到接口拒绝当前 token：刷新登录态后重试
///
/// 三家厂商对「token 不被接受」的判定条件不同（HTTP 401、业务码、自定义头），
/// 但处理动作一致，所以由子类识别后统一抛出这个标记，交给 [AccountAuthServiceBase.runWithToken]
/// 刷新重试。
class AccountAuthTokenRejected implements Exception {
  const AccountAuthTokenRejected();
}

/// 账号型厂商共用的登录态骨架
///
/// 三个厂商（小浣熊 / AutoClaw / Loomy）的账号缓存、选号、并发刷新合流、
/// 账号增删改排序与 [RaccoonAccountRouter] 的交互完全一致，差异只在登录协议、
/// 续期协议与额度接口。这里只上提「与厂商协议无关」的部分，避免三份实现各自
/// 漂移；厂商专属逻辑仍留在子类。
///
/// 测试注入字段（`accountsLoaderForTest` 等）是各子类的 **static**，不能继承或
/// 重写。子类通过 [accountsLoaderHook] 等受保护 getter 把自己的 static 转给基类，
/// 避免三家共享同一份 static 导致测试串数据。
abstract class AccountAuthServiceBase extends AccountAuthService {
  /// 账号表读写（`ai_accounts`）
  @protected
  final AiAccountRepository repository = AiAccountRepository.instance;

  /// 多账号选号、亲和与冷却（纯进程内状态，三家共用同一个单例）
  @protected
  final RaccoonAccountRouter router = RaccoonAccountRouter.instance;

  /// accountId → 登录态（进程内缓存；登录/刷新/退出都会更新）
  final Map<String, AiAccount> _cache = {};

  /// accountId → 正在进行的刷新（合并并发刷新，避免 refresh token 被重复消费）
  final Map<String, Future<AiAccount>> _refreshing = {};

  // ── 子类接入钩子 ─────────────────────────────────────────

  /// 测试注入：绕开数据库直接给账号列表（默认无注入）
  ///
  /// 子类必须返回自己的 static 字段，不能共用一份，否则测试会互相串数据。
  @protected
  Future<List<AiAccount>> Function(String providerId)? get accountsLoaderHook => null;

  /// 测试注入：绕开数据库直接返回 token（默认无注入）
  @protected
  Future<String?> Function(String providerId)? get accessTokenLoaderHook => null;

  /// 测试注入：登录落库（默认写 `ai_accounts` 表）
  @protected
  Future<void> Function(AiAccount account)? get accountSaverHook => null;

  /// 测试注入：额度/签到被拒后刷新账号（默认走 [refreshAccount]）
  @protected
  Future<AiAccount> Function(AiAccount account)? get accountRefresherHook => null;

  /// 是否支持通过厂商续期接口刷新 access token
  ///
  /// Loomy 没有续期接口，「刷新」只是检查登录态是否还活着；这类厂商不需要
  /// 合并并发刷新。
  @protected
  bool get supportsTokenRefresh => true;

  /// 提前多久把 access token 视为临期（刷新成本与 token 轮换策略由厂商决定）
  @protected
  Duration get tokenRefreshMargin;

  // ── 未登录异常文案 ───────────────────────────────────────

  /// 异常/日志文案里的厂商名前缀
  ///
  /// 西文厂商名（`Loomy` / `AutoClaw`）后要加一个空格，中文厂商名（`小浣熊`）
  /// 不加，否则文案里会出现「小浣熊 账号」这种别扭的断句。子类按需覆写。
  @protected
  String get vendorLabelPrefix => '$vendorLabel ';

  @override
  AccountAuthRequiredException notLoggedIn(String providerId) =>
      authRequired(providerId, '$vendorLabelPrefix账号未登录或已过期，请到「设置 → AI 模型配置」重新登录');

  @override
  AccountAuthRequiredException authExpired(String providerId) =>
      authRequired(providerId, '$vendorLabelPrefix登录已失效，请重新登录');

  /// 构造带厂商文案的「未登录 / 登录失效」异常
  ///
  /// 小浣熊保留自己的异常子类（现有调用方与测试按类型断言），其余厂商用
  /// 通用异常，由 `kind` 区分。文案由子类传入，基类只负责带上 [kind]。
  @protected
  AccountAuthRequiredException authRequired(String providerId, String message) =>
      AccountAuthRequiredException(providerId, message: message, kind: kind);

  // ── 账号读取 ─────────────────────────────────────────────

  @override
  Future<List<AiAccount>> accountsFor(String providerId, {bool forceReload = false}) async {
    final loader = accountsLoaderHook;
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
    final stored = (await repository.getByProvider(providerId)).where((account) => account.kind == kind).toList();
    for (final account in stored) {
      _cache[account.id] = account;
    }
    return stored;
  }

  List<AiAccount> _cachedFor(String providerId) {
    final result = _cache.values.where((a) => a.providerId == providerId && a.kind == kind).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return result;
  }

  // ── 发信前选号 ───────────────────────────────────────────

  @override
  Future<AccountSession?> sessionForRequest(
    String providerId, {
    String routing = AiProvider.defaultAccountRouting,
    String affinity = AiProvider.defaultAccountAffinity,
    AiRequestScope? scope,
    Set<String> triedAccountIds = const {},
    bool advance = true,
  }) async {
    final loader = accessTokenLoaderHook;
    if (loader != null) {
      final token = await loader(providerId);
      if (token == null || token.trim().isEmpty) return null;
      final now = DateTime.now();
      return AccountSession(
        account: AiAccount(
          id: 'test-account',
          providerId: providerId,
          kind: kind,
          accessToken: token,
          createdAt: now,
          updatedAt: now,
        ),
        accessToken: token,
      );
    }

    final accounts = await accountsFor(providerId);
    if (accounts.isEmpty) return null;

    final selection = router.select(
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
        throw authRequired(providerId, '$vendorLabelPrefix账号已全部停用，请到「设置 → AI 模型配置」启用一个账号');
      }
      final untried = enabled.where((a) => !triedAccountIds.contains(a.id)).toList();
      if (untried.isNotEmpty) {
        throw authRequired(providerId, '$vendorLabelPrefix账号都在限流冷却中，稍后重试');
      }
      // 本次请求已经把能用的账号都试过了：交回调用方 rethrow 原始错误
      return null;
    }

    final token = await accessTokenForAccount(selection.account);
    if (token == null || token.trim().isEmpty) {
      // 这个账号的凭证已经废了：标记冷却，让本次请求换下一个账号
      router.markFailed(
        selection.account,
        const FormatException('账号凭证不可用'),
        affinity: AccountAffinity.fromId(affinity),
      );
      return null;
    }
    return AccountSession(account: selection.account, accessToken: token);
  }

  @override
  void markAccountSucceeded(AiAccount account) => router.markSucceeded(account);

  @override
  void markAccountFailed(AiAccount account, Object error, {String affinity = AiProvider.defaultAccountAffinity}) {
    router.markFailed(account, error, affinity: AccountAffinity.fromId(affinity));
  }

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
    return router.select(
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

  @override
  Future<AiAccount?> accountById(String accountId) async {
    final cached = _cache[accountId];
    if (cached != null) return cached;
    final stored = await repository.getById(accountId);
    if (stored != null) _cache[stored.id] = stored;
    return stored;
  }

  @override
  AiAccount? accountFromCache(String accountId) => _cache[accountId];

  @override
  bool isAccountCooling(String accountId) => router.isCooling(accountId);

  // ── token 读取与刷新 ─────────────────────────────────────

  /// 取 access token：临期/过期先刷新，刷新被厂商明确拒绝才标记失效
  ///
  /// Loomy 没有续期接口，覆写本方法直接判失效（见 `LoomyAuthService`）。
  @override
  Future<String?> accessTokenForAccount(AiAccount account) async {
    final loader = accessTokenLoaderHook;
    if (loader != null) return loader(account.providerId);

    // 账号列表来自测试注入时不要去读库：那个账号对象就是唯一事实
    final current = accountsLoaderHook != null ? account : await refreshCacheFromStore(account);
    if (current.accessToken.trim().isEmpty) return null;
    final needsRefresh = current.isExpired || current.isStale(margin: tokenRefreshMargin);
    if (!needsRefresh) return current.accessToken;
    try {
      final refreshed = await refreshAccount(current.id, force: true);
      return refreshed.accessToken;
    } on AccountAuthRequiredException {
      // 只有厂商明确拒绝（4xx / 没有 refresh token）才标记失效；
      // 网络抖动不能把用户踢下线
      await markAccountExpired(current);
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AiAccount> refreshAccount(String accountId, {bool force = false}) {
    if (!supportsTokenRefresh) return reloadAccount(accountId, force: force);
    final running = _refreshing[accountId];
    if (running != null) return running;
    final future = reloadAccount(accountId, force: force).whenComplete(() {
      _refreshing.remove(accountId);
    });
    _refreshing[accountId] = future;
    return future;
  }

  /// 按厂商协议真正执行一次刷新（基类负责合并并发与维护缓存）
  @protected
  Future<AiAccount> reloadAccount(String accountId, {required bool force});

  @override
  Future<AiAccount> refresh(String providerId, {bool force = false}) async {
    final accounts = await accountsFor(providerId, forceReload: true);
    if (accounts.isEmpty) throw notLoggedIn(providerId);
    return refreshAccount(accounts.first.id, force: force);
  }

  // ── 登录落库 ─────────────────────────────────────────────

  /// 落库一个登录态：同一厂商账号重复登录时覆盖旧行，新账号追加到末尾
  ///
  /// 去重判据（uid / 脱敏手机号）与 sortOrder 追加规则三家一致；厂商差异
  /// （session、access/refresh、设备号、资料补全）由 [buildAccount] 负责。
  /// 探测账号不拉资料（[buildAccount] 的 `fetchProfile` 为 false），避免为
  /// 了去重多打一次用户信息接口。
  @protected
  Future<AiAccount> persistLogin(
    String providerId, {
    String? accountId,
    required Future<AiAccount> Function({required String accountId, AiAccount? previous, required bool fetchProfile})
    buildAccount,
  }) async {
    final existing = await accountsFor(providerId, forceReload: true);
    AiAccount? previous = accountId == null ? null : existing.where((a) => a.id == accountId).firstOrNull;
    if (previous == null) {
      final probe = await buildAccount(accountId: '', fetchProfile: false);
      for (final account in existing) {
        if (account.isSameVendorAccount(probe)) {
          previous = account;
          break;
        }
      }
    }

    final account = await buildAccount(
      accountId: previous?.id ?? const Uuid().v4(),
      previous: previous,
      fetchProfile: true,
    );
    final next = previous == null ? account.copyWith(sortOrder: _nextSortOrder(existing)) : account;
    await saveAccount(next);
    LoggerService.instance.logAI(
      previous == null ? '$vendorLabelPrefix新增账号: ${next.label}' : '$vendorLabelPrefix账号已更新: ${next.label}',
    );
    return next;
  }

  int _nextSortOrder(List<AiAccount> existing) {
    if (existing.isEmpty) return 0;
    return existing.map((a) => a.sortOrder).reduce((a, b) => a > b ? a : b) + 1;
  }

  // ── 账号管理 ─────────────────────────────────────────────

  @override
  Future<void> logout(String accountId) async {
    _cache.remove(accountId);
    router.forget(accountId);
    await repository.delete(accountId);
  }

  @override
  Future<void> logoutProvider(String providerId) async {
    // 缓存与库里可能各有一部分账号（后者是其他入口刚写入的），两边并集都要
    // 清掉选号状态，避免已删除账号的冷却/亲和残留。
    final cached = _cache.values.where((account) => account.providerId == providerId).toList();
    final stored = await accountsFor(providerId, forceReload: true);
    final accountsById = <String, AiAccount>{
      for (final account in cached) account.id: account,
      for (final account in stored) account.id: account,
    };
    final accounts = accountsById.values.toList();
    for (final account in accounts) {
      _cache.remove(account.id);
    }
    router.resetProvider(providerId, accounts: accounts);
    await repository.deleteByProvider(providerId);
  }

  @override
  Future<AiAccount> updateAccount(AiAccount account, {String? alias, bool? enabled}) async {
    final next = account.copyWith(alias: alias, enabled: enabled);
    await saveAccount(next);
    return next;
  }

  @override
  Future<List<AiAccount>> reorderAccounts(String providerId, List<String> orderedIds) async {
    final accounts = await accountsFor(providerId, forceReload: true);
    final byId = {for (final a in accounts) a.id: a};
    final next = <AiAccount>[];
    var index = 0;
    for (final id in orderedIds) {
      final account = byId.remove(id);
      if (account == null) continue;
      next.add(account.copyWith(sortOrder: index++));
    }
    // 没出现在 orderedIds 里的账号排到末尾，避免丢失
    for (final account in byId.values) {
      next.add(account.copyWith(sortOrder: index++));
    }
    await repository.upsertAll(next);
    for (final account in next) {
      _cache[account.id] = account;
    }
    return next;
  }

  @override
  void clearCache() {
    _cache.clear();
    router.clearAll();
  }

  // ── 账号写库与状态 ───────────────────────────────────────

  /// 落库并在成功后再更新缓存（写失败时界面不能看到「已成功」的假状态）
  @protected
  Future<void> saveAccount(AiAccount account) async {
    final saver = accountSaverHook;
    if (saver != null) {
      await saver(account);
      _cache[account.id] = account;
      return;
    }
    await repository.upsert(account);
    _cache[account.id] = account;
  }

  /// 缓存里的那份可能已被其他入口刷新过，优先读库里的最新值
  @protected
  Future<AiAccount> refreshCacheFromStore(AiAccount account) async {
    final stored = await repository.getById(account.id);
    if (stored == null) return account;
    _cache[stored.id] = stored;
    return stored;
  }

  @protected
  void cacheAccount(AiAccount account) => _cache[account.id] = account;

  @protected
  void evictCachedAccount(String accountId) => _cache.remove(accountId);

  /// 把账号标记为过期（只有厂商明确拒绝时才调用，网络抖动不算）
  @protected
  Future<void> markAccountExpired(AiAccount account) async {
    await saveAccount(account.copyWith(status: AiAccount.statusExpired, updatedAt: DateTime.now()));
  }

  /// 按 id 标记账号过期；账号已被删除时直接忽略
  @protected
  Future<void> markAccountExpiredById(String accountId) async {
    final stored = await repository.getById(accountId);
    if (stored == null) return;
    await markAccountExpired(stored);
  }

  /// 清掉并发刷新锁（测试收尾用；避免上一个用例的 Future 挂在表里）
  @protected
  void clearRefreshLocks() => _refreshing.clear();

  // ── 带登录态执行一次接口 ─────────────────────────────────

  /// 带登录态执行一次只读/签到接口：被服务端拒绝时刷新一次再试，仍被拒才
  /// 标记过期——与发信层的 401 处理口径一致，不把「接口查不到」当成「登录失效」。
  @protected
  Future<T> runWithToken<T>(AiAccount account, Future<T> Function(String token) run) async {
    final token = await accessTokenForAccount(account);
    if (token == null || token.trim().isEmpty) {
      throw notLoggedIn(account.providerId);
    }
    try {
      return await run(token);
    } on AccountAuthTokenRejected {
      final refresher = accountRefresherHook;
      final AiAccount refreshed;
      try {
        refreshed = refresher != null ? await refresher(account) : await refreshAccount(account.id, force: true);
      } on AccountAuthRequiredException {
        rethrow;
      }
      try {
        return await run(refreshed.accessToken);
      } on AccountAuthTokenRejected {
        await markAccountExpired(refreshed);
        throw authExpired(account.providerId);
      }
    }
  }
}
