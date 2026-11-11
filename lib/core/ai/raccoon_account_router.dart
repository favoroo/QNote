import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_account_routing.dart';

/// 一次请求的会话标识：选号时用来判断「这段对话上次用的哪个账号」
///
/// 拆成两个 key 是为了表达两种亲和粒度：
/// - [sessionKey] 整段对话不变（会话亲和：同一对话固定账号，换对话才轮换）；
/// - [turnKey] 每条用户消息变一次（每轮轮换：同一条消息内的多步工具循环保持
///   同一账号，用户再说一句才轮到下一个账号）。
///
/// 没有会话概念的调用（日记提取、每日评分、识图工具）传 null，选号器退化为
/// 按场景名做 key —— 效果等同于「顺序/轮流」策略本身。
class AiRequestScope {
  /// 整段对话的稳定标识（通常是小Q 的会话 id）
  final String sessionKey;

  /// 本次用户消息的标识；同一条消息内的多次发信共用它
  final String turnKey;

  const AiRequestScope({required this.sessionKey, required this.turnKey});

  /// 非对话类调用（无会话概念）的兜底作用域
  const AiRequestScope.scene(String scene) : sessionKey = scene, turnKey = scene;
}

/// 单个账号的进程内健康度（智能策略打分用）
class _AccountHealth {
  final List<bool> outcomes = [];
  int uses = 0;
  int consecutiveFailures = 0;

  static const int windowSize = 5;

  void recordSuccess() {
    consecutiveFailures = 0;
    uses++;
    outcomes.add(true);
    if (outcomes.length > windowSize) outcomes.removeAt(0);
  }

  void recordFailure() {
    consecutiveFailures++;
    uses++;
    outcomes.add(false);
    if (outcomes.length > windowSize) outcomes.removeAt(0);
  }

  double get successRate {
    if (outcomes.isEmpty) return 1;
    return outcomes.where((o) => o).length / outcomes.length;
  }
}

/// 一次选号的结果
class AccountSelection {
  final AiAccount account;

  /// 本次请求是否因为「会话亲和」而被固定在某个账号上（日志与排查用）
  final bool keptByAffinity;

  const AccountSelection({required this.account, this.keptByAffinity = false});
}

/// 订阅账号的选号与亲和（语义对齐 magpie 的 `Routing` + `Affinity`）
///
/// 分工：
/// - `ApiKeyPool`：同一厂商的多把 **API Key** 逐请求轮询；
/// - `AiRouteService`：跨厂商的 **模型** 级轮换；
/// - 本类：同一厂商的多 **订阅账号** 轮换 —— 三者互不重叠。
///
/// 纯进程内状态（游标、亲和记忆、冷却表、健康度），不落库：账号本身与策略
/// 存在数据库，选到谁只影响这一次请求。
class RaccoonAccountRouter {
  RaccoonAccountRouter._();

  static final RaccoonAccountRouter instance = RaccoonAccountRouter._();

  /// 账号撞限流后的默认冷却（额度通常按分钟滚动回填）
  static const Duration defaultCooldown = Duration(minutes: 1);

  /// 冷却上限：不把某个账号关到天荒地老
  static const Duration maxCooldown = Duration(minutes: 10);

  /// 连接类/5xx 这类瞬时故障的短冷却：让位给别的账号，但很快回池
  static const Duration transientCooldown = Duration(seconds: 30);

  /// 亲和记忆的保留时长（与 magpie 的 `stickKeep` 同量级）
  static const Duration affinityKeep = Duration(hours: 24);

  /// providerId → 轮流游标
  final Map<String, int> _cursor = {};

  /// 亲和 key → (accountId, 记录时刻)
  final Map<String, _AffinityStick> _sticks = {};

  /// accountId → 冷却截止
  final Map<String, DateTime> _cooldownUntil = {};

  final Map<String, _AccountHealth> _health = {};

  /// 选出本次请求要用的账号
  ///
  /// [triedAccountIds] 是「本次请求已经试过并失败的账号」，会被排除（[strict]
  /// 除外）—— 否则换号后又会选回刚失败的那个，形成死循环。
  ///
  /// [advance] 为 false 时只看当前会选谁、不推进轮询游标与亲和记忆，
  /// 给界面预检这类不发请求的调用方用。
  AccountSelection? select({
    required String providerId,
    required List<AiAccount> accounts,
    required AccountRouting routing,
    required AccountAffinity affinity,
    AiRequestScope? scope,
    Set<String> triedAccountIds = const {},
    bool advance = true,
  }) {
    final candidates = accounts.where((a) => a.enabled).toList();
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) {
      final only = candidates.first;
      // 单账号：亲和与策略都没有意义，但「试过且失败」要如实返回 null，
      // 让发信层走原有重试/报错链路，而不是无限重发同一个账号
      if (triedAccountIds.contains(only.id)) return null;
      return AccountSelection(account: only, keptByAffinity: true);
    }

    final now = DateTime.now();
    _pruneExpired(now);

    // 1) 严格亲和：无视冷却，始终回到记住的账号；一旦它已经失败过，就直接
    //    返回 null（让错误抛给用户），而不是退到策略里换一个账号 —— 换号就
    //    违背了 strict 的语义。
    if (affinity == AccountAffinity.strict) {
      final key = _affinityKey(providerId, affinity, scope);
      final stick = key == null ? null : _sticks[key];
      if (stick != null) {
        AiAccount? stuck;
        for (final account in candidates) {
          if (account.id == stick.accountId) {
            stuck = account;
            break;
          }
        }
        if (stuck == null) {
          // 记住的账号已被删除/停用：清掉记忆，按策略重新选一次
          _sticks.remove(key);
        } else if (triedAccountIds.contains(stuck.id)) {
          return null;
        } else {
          return AccountSelection(account: stuck, keptByAffinity: true);
        }
      }
    }

    // 2) 会话/每轮亲和：记住的账号仍可用（未冷却、未被本次试过）就继续用它。
    //    冷却优先于亲和 —— 与 magpie 的 "resting" 判定一致：账号被限流时
    //    必须让位，否则整条对话会跟着它一起卡死。
    if (affinity != AccountAffinity.off) {
      final stuck = _stuckAccount(providerId, affinity, scope, candidates, now);
      if (stuck != null && !_isCooling(stuck.id, now) && !triedAccountIds.contains(stuck.id)) {
        return AccountSelection(account: stuck, keptByAffinity: true);
      }
    }

    // 3) 按策略在「未冷却且本次未试过」的账号里选
    final selectable = candidates
        .where((a) => !_isCooling(a.id, now))
        .where((a) => !triedAccountIds.contains(a.id))
        .toList();
    if (selectable.isEmpty) {
      // 全部冷却/试过：交回调用方决定是排队等待还是直接报错
      return null;
    }

    final chosen = switch (routing) {
      AccountRouting.rotate => _rotate(providerId, selectable, advance: advance),
      AccountRouting.failover => selectable.first,
      AccountRouting.smart => _smart(selectable),
    };

    if (advance) {
      _remember(providerId, affinity, scope, chosen.id, now);
      LoggerService.instance.logAI(
        '${_vendorLabel(chosen)}账号选号：策略=${routing.label} '
        '亲和=${affinity.label} 选中 ${chosen.label}（${chosen.id}）',
        details: '候选 ${selectable.length} 个 / 共 ${candidates.length} 个已启用',
      );
    }
    return AccountSelection(account: chosen);
  }

  /// 记录一次账号失败：进入冷却，并清掉它占着的亲和位置
  ///
  /// 清亲和是必须的：否则冷却结束后（或 strict 之外的策略下）会立刻回到
  /// 刚刚失败的账号上，用户看到的还是同一条报错。
  void markFailed(AiAccount account, Object error, {AccountAffinity affinity = AccountAffinity.session}) {
    _health.putIfAbsent(account.id, _AccountHealth.new).recordFailure();
    final cooldown = cooldownFor(error);
    _cooldownUntil[account.id] = DateTime.now().add(cooldown);
    if (affinity != AccountAffinity.strict) {
      _sticks.removeWhere((_, stick) => stick.accountId == account.id);
    }
    LoggerService.instance.logAI(
      '${_vendorLabel(account)}账号 ${account.label} '
      '失败进入冷却 ${cooldown.inSeconds}s',
      level: LogLevel.warning,
      details: error.toString(),
    );
  }

  void markSucceeded(AiAccount account) {
    _health.putIfAbsent(account.id, _AccountHealth.new).recordSuccess();
    // 成功一次就说明这个账号可用，提前解除它自己的冷却（例如限流其实只影响了
    // 单个请求）—— 但保留其他账号的冷却不动
    _cooldownUntil.remove(account.id);
  }

  /// 账号被删除/退出登录后清掉它的残留状态
  void forget(String accountId) {
    _health.remove(accountId);
    _cooldownUntil.remove(accountId);
    _sticks.removeWhere((_, stick) => stick.accountId == accountId);
  }

  /// 厂商条目删除 / 切回 API Key 模式时清掉整组状态
  ///
  /// 健康度按 accountId 记账（账号 id 是 uuid，不含厂商前缀），所以除了清游标
  /// 与亲和记忆，还要把该厂商现有账号的健康度一起清掉。
  void resetProvider(String providerId, {List<AiAccount> accounts = const []}) {
    _cursor.remove(providerId);
    _sticks.removeWhere((key, _) => key.startsWith('$providerId|'));
    for (final account in accounts) {
      _health.remove(account.id);
      _cooldownUntil.remove(account.id);
    }
  }

  /// 账号是否在冷却中
  bool isCooling(String accountId) => _isCooling(accountId, DateTime.now());

  bool _isCooling(String accountId, DateTime now) {
    final until = _cooldownUntil[accountId];
    if (until == null) return false;
    if (!until.isAfter(now)) {
      _cooldownUntil.remove(accountId);
      return false;
    }
    return true;
  }

  /// 冷却时长：限流类按 `Retry-After`，连接/5xx 用短冷却
  Duration cooldownFor(Object error) {
    Duration cooldown = defaultCooldown;
    if (_isRateLimited(error)) {
      cooldown = _retryAfter(error) ?? defaultCooldown;
    } else if (_isTransient(error)) {
      cooldown = transientCooldown;
    }
    return cooldown > maxCooldown ? maxCooldown : cooldown;
  }

  static bool _isRateLimited(Object error) {
    final status = _statusOf(error);
    if (status == 429) return true;
    final text = error.toString().toLowerCase();
    return text.contains('rate limit') ||
        text.contains('quota') ||
        text.contains('exhausted') ||
        text.contains('insufficient');
  }

  static String _vendorLabel(AiAccount account) {
    switch (account.kind) {
      case AiAccount.kindAutoClaw:
        return 'AutoClaw';
      case AiAccount.kindLoomy:
        return 'Loomy';
      default:
        return '小浣熊';
    }
  }

  static bool _isTransient(Object error) {
    final status = _statusOf(error);
    if (status != null && status >= 500) return true;
    final text = error.toString();
    return text.contains('connection') ||
        text.contains('timeout') ||
        text.contains('SocketException') ||
        text.contains('HandshakeException');
  }

  static int? _statusOf(Object error) {
    try {
      final dynamic dynamicError = error;
      final dynamic response = dynamicError.response;
      final dynamic status = response?.statusCode;
      return status is int ? status : null;
    } catch (_) {
      return null;
    }
  }

  static Duration? _retryAfter(Object error) {
    try {
      final dynamic dynamicError = error;
      final dynamic headers = dynamicError.response?.headers;
      final dynamic raw = headers?.value('retry-after');
      final seconds = int.tryParse('${raw ?? ''}'.trim());
      if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    } catch (_) {}
    return null;
  }

  AiAccount? _stuckAccount(
    String providerId,
    AccountAffinity affinity,
    AiRequestScope? scope,
    List<AiAccount> candidates,
    DateTime now,
  ) {
    final key = _affinityKey(providerId, affinity, scope);
    if (key == null) return null;
    final stick = _sticks[key];
    if (stick == null) return null;
    if (now.difference(stick.at) > affinityKeep) {
      _sticks.remove(key);
      return null;
    }
    for (final account in candidates) {
      if (account.id == stick.accountId) return account;
    }
    // 记住的账号已被删除/停用：清掉，让策略重新选
    _sticks.remove(key);
    return null;
  }

  void _remember(String providerId, AccountAffinity affinity, AiRequestScope? scope, String accountId, DateTime now) {
    if (affinity == AccountAffinity.off) return;
    final key = _affinityKey(providerId, affinity, scope);
    if (key == null) return;
    _sticks[key] = _AffinityStick(accountId: accountId, at: now);
  }

  /// 亲和记忆的 key：会话亲和按 sessionKey，每轮轮换按 turnKey
  String? _affinityKey(String providerId, AccountAffinity affinity, AiRequestScope? scope) {
    if (scope == null) return null;
    final part = affinity == AccountAffinity.session ? scope.sessionKey : scope.turnKey;
    if (part.trim().isEmpty) return null;
    return '$providerId|$part';
  }

  AiAccount _rotate(String providerId, List<AiAccount> selectable, {required bool advance}) {
    final cursor = _cursor[providerId] ?? 0;
    final index = cursor % selectable.length;
    if (advance) _cursor[providerId] = (index + 1) % selectable.length;
    return selectable[index];
  }

  /// 智能策略：成功率为主，其次「用得少」微调均衡
  ///
  /// 不做额外分类调用、也不读厂商额度：订阅账号的剩余额度没有公开接口，
  /// 只能用实际成败与使用次数近似，与路由组的智能策略保持同一套口径。
  AiAccount _smart(List<AiAccount> selectable) {
    AiAccount best = selectable.first;
    var bestScore = double.negativeInfinity;
    final maxUses = selectable.map((a) => _health[a.id]?.uses ?? 0).fold<int>(0, (a, b) => a > b ? a : b);
    for (final account in selectable) {
      final health = _health[account.id];
      final successRate = health?.successRate ?? 1.0;
      final uses = health?.uses ?? 0;
      final usageScore = maxUses == 0 ? 1.0 : 1 - (uses / (maxUses + 1));
      final score = successRate * 0.7 + usageScore * 0.3;
      if (score > bestScore) {
        bestScore = score;
        best = account;
      }
    }
    return best;
  }

  void _pruneExpired(DateTime now) {
    _cooldownUntil.removeWhere((_, until) => !until.isAfter(now));
    _sticks.removeWhere((_, stick) => now.difference(stick.at) > affinityKeep);
  }

  /// 清空全部进程内状态（数据管理页清空数据、测试收尾用）
  ///
  /// 账号配置与登录态都在数据库里，清掉这些只是让下一次请求重新按策略选号，
  /// 不会丢任何用户配置。
  void clearAll() {
    _cursor.clear();
    _sticks.clear();
    _cooldownUntil.clear();
    _health.clear();
  }

  @visibleForTesting
  void resetForTest() => clearAll();
}

class _AffinityStick {
  final String accountId;
  final DateTime at;

  const _AffinityStick({required this.accountId, required this.at});
}
