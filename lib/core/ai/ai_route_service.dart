import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:qnote_flutter/core/ai/api_key_pool.dart';
import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';

/// 一次选路的结果：本次用哪个成员，以及按策略排好的后备成员
///
/// [fallbacks] 含全部候选（含 [config] 自己），顺序即「本成员失败后依次尝试」的顺序，
/// 供发信层在正文未输出前做组内故障切换（见 [AiModelRoute.next]）。
class AiRouteSelection {
  final AiConfig config;
  final List<AiConfig> candidates;
  final AiRouteGroup group;

  /// 本次请求带图片：后续切换只在支持识图的成员间进行
  final bool requireVision;

  const AiRouteSelection({
    required this.config,
    required this.candidates,
    required this.group,
    this.requireVision = false,
  });

  AiModelRoute toRoute() => AiModelRoute._(
        groupId: group.id,
        candidates: candidates,
        requireVision: requireVision,
      );
}

/// 一次运行（一条用户消息 / 一次提取调用）的组内切换状态
///
/// 刻意做成**每运行时新建的对象**而不是 [AiRouteService] 的字段：`AiService` 是
/// 单例，主对话、悬浮小Q、日记提取会并发使用，任何「本次已试过哪些成员」这类
/// 状态放进单例都会串台。
class AiModelRoute {
  AiModelRoute._({
    required this.groupId,
    required List<AiConfig> candidates,
    required this.requireVision,
  }) : _candidates = candidates;

  final String groupId;

  /// 本次请求是否需要成员支持识图（带图片时不允许切到看不见图的成员）
  final bool requireVision;

  final List<AiConfig> _candidates;
  final Set<String> _tried = {};

  /// 本次运行实际使用的成员（[next] 会更新它，供日志与用量归因）
  AiConfig? active;

  int get candidateCount => _candidates.length;

  /// 新一轮推理开始时重置「本次已试过的成员」
  ///
  /// AgentLoop 一条用户消息会多次调用发信方法（每步工具循环一次）。上一轮切换到的
  /// 成员要由 [active] 延续下来，否则每一步都会从第一个成员重新开头、再失败一轮；
  /// 而「已试过」只对单次请求有效，跨轮保留会让后续步骤失去换成员的机会。
  void beginRequest() => _tried.clear();

  /// 本次运行开始时选中的成员
  AiConfig get initial {
    active ??= _candidates.first;
    return _candidates.first;
  }

  /// 当前成员失败后换下一个成员；没有可换的成员时返回 null（交回原有重试逻辑）
  ///
  /// [error] 用于判定冷却时长：Key 级配额错误按端点给的 `Retry-After`，连接类与
  /// 5xx 用较短的瞬态冷却。切换是「这个成员现在不可用」，与 Key 级轮询是两层：
  /// Key 轮询已在 [ApiKeyPool] 层把同厂商多把 Key 耗尽，走到这里说明整个成员该让位。
  AiConfig? next(AiConfig failed, Object error) {
    final service = AiRouteService.instance;
    final failedKey = _key(failed);
    _tried.add(failedKey);
    service.markMemberFailed(failed, error);

    final index = _candidates.indexWhere((c) => _key(c) == failedKey);
    if (index < 0) return null;
    for (var step = 1; step < _candidates.length; step++) {
      final candidate = _candidates[(index + step) % _candidates.length];
      final key = _key(candidate);
      if (_tried.contains(key)) continue;
      if (service.isCooling(key)) continue;
      if (requireVision && !ModelVisionCapability.supportsVision(candidate)) {
        continue;
      }
      active = candidate;
      LoggerService.instance.logAI(
        '路由组「${service.groupName(groupId)}」成员 $failedKey 失败，'
        '本次请求切换到成员 $key',
        level: LogLevel.warning,
      );
      return candidate;
    }
    return null;
  }

  /// 记一次成功（供智能策略的成功率与耗时统计）
  void recordSuccess(AiConfig config, {Duration? elapsed}) {
    AiRouteService.instance.markMemberSucceeded(config, elapsed: elapsed);
  }

  static String _key(AiConfig config) =>
      '${config.providerId}::${config.modelName}';
}

/// 单成员的健康度（进程内，用于智能策略与冷却判定）
class _MemberHealth {
  final List<bool> outcomes = [];
  double? latencyEwmaMs;
  int uses = 0;
  int consecutiveFailures = 0;

  static const int windowSize = 5;

  void recordSuccess({Duration? elapsed}) {
    consecutiveFailures = 0;
    uses++;
    outcomes.add(true);
    if (outcomes.length > windowSize) outcomes.removeAt(0);
    if (elapsed != null) {
      final ms = elapsed.inMilliseconds.toDouble();
      latencyEwmaMs = latencyEwmaMs == null ? ms : latencyEwmaMs! * 0.6 + ms * 0.4;
    }
  }

  void recordFailure() {
    consecutiveFailures++;
    uses++;
    outcomes.add(false);
    if (outcomes.length > windowSize) outcomes.removeAt(0);
  }

  double get successRate {
    if (outcomes.isEmpty) return 1;
    final ok = outcomes.where((o) => o).length;
    return ok / outcomes.length;
  }
}

/// 模型路由组的选路与运行状态
///
/// 纯内存状态（轮询游标、冷却表、健康度、上次使用），与 [ApiKeyPool] 的分工：
/// - `ApiKeyPool`：**同一厂商条目的多把 Key** 逐请求轮询（已存在的能力，不改动）；
/// - 本类：**跨成员（可跨厂商）的模型级** 轮询 / 权重 / 智能 / 故障切换。
///
/// 组配置改动后调用 [resetGroup] 清掉旧游标，避免「改了顺序还在按旧轮次走」。
class AiRouteService {
  AiRouteService._();

  static final AiRouteService instance = AiRouteService._();

  /// 用户主动换成员/切策略后旧的轮询游标与冷却没有意义
  static const Duration transientCooldown = Duration(seconds: 30);
  static const Duration memberCooldown = Duration(minutes: 1);
  static const Duration maxCooldown = Duration(minutes: 10);

  /// 智能策略里「最慢」的参照时长：越接近它耗时得分越低
  static const int latencyCeilingMs = 20000;

  final Map<String, int> _rotateCursor = {};

  /// 权重策略的平滑轮询累计值（`groupId|memberKey` → 当前权重）
  final Map<String, int> _weightCurrent = {};
  final Map<String, _MemberHealth> _health = {};
  final Map<String, DateTime> _cooldownUntil = {};
  final Map<String, String> _lastUsed = {};
  final Map<String, String> _groupNames = {};

  /// 组最近一次实际使用的成员编码（`providerId::modelName`），仅供界面展示
  String? lastUsedMember(String groupId) => _lastUsed[groupId];

  /// 组名的进程内缓存（日志里要显示「路由组「xxx」」，而选路时手上只有配置对象）
  String groupName(String groupId) => _groupNames[groupId] ?? groupId;

  /// 成员是否在冷却中
  bool isCooling(String memberKey) {
    final until = _cooldownUntil[memberKey];
    if (until == null) return false;
    if (!until.isAfter(DateTime.now())) {
      _cooldownUntil.remove(memberKey);
      return false;
    }
    return true;
  }

  /// 组配置变化后清掉该组的轮询游标、展示缓存与成员健康度
  ///
  /// 成员顺序/策略/权重改了以后，旧游标对应的「下一个是谁」已经没意义，
  /// 留着会让用户觉得「改了配置但轮次没变」。
  void resetGroup(String groupId, {List<RouteGroupMember> members = const []}) {
    _rotateCursor.remove(groupId);
    _lastUsed.remove(groupId);
    _groupNames.remove(groupId);
    for (final member in members) {
      final memberKey = '${member.providerId}::${member.modelName}';
      resetMember(memberKey);
      _weightCurrent.remove('$groupId|$memberKey');
    }
  }

  /// 清掉某成员的健康度（模型被停用/厂商被删后不再有意义）
  void resetMember(String memberKey) {
    _health.remove(memberKey);
    _cooldownUntil.remove(memberKey);
  }

  /// 记录一次成员失败并进入冷却
  void markMemberFailed(AiConfig config, Object error) {
    final key = '${config.providerId}::${config.modelName}';
    _health.putIfAbsent(key, _MemberHealth.new).recordFailure();
    final cooldown = _cooldownFor(error);
    _cooldownUntil[key] = DateTime.now().add(cooldown);
    LoggerService.instance.logAI(
      '路由组成员 ${config.providerId} · ${config.modelName} 失败进入冷却 '
      '${cooldown.inSeconds}s',
      level: LogLevel.warning,
      details: error.toString(),
    );
  }

  /// 记录一次成员成功
  void markMemberSucceeded(AiConfig config, {Duration? elapsed}) {
    final key = '${config.providerId}::${config.modelName}';
    _health.putIfAbsent(key, _MemberHealth.new).recordSuccess(elapsed: elapsed);
  }

  /// 按组策略选一个成员；无可用成员时抛 [NoModelConfiguredException]
  ///
  /// [preferVision] 由调用方按「本次请求是否带图片」传入：为真且组内确有识图成员时，
  /// 候选集合收敛到识图成员，避免把图片发给看不见画面的模型。
  ///
  /// [advance] 为 false 表示「只看当前轮到谁、不消耗这一轮」：给可用性预检、
  /// 能力判定这类**不发请求**的调用方用。否则一次提问里的预检会把轮次提前用掉，
  /// 真正的请求反而轮到别的成员，用户会觉得「轮流没按预期走」。
  AiRouteSelection select(
    AiRouteGroup group,
    List<AiProvider> providers, {
    bool preferVision = false,
    bool advance = true,
  }) {
    _groupNames[group.id] = group.name;
    final allMembers = _feasibleMembers(group, providers);
    if (allMembers.isEmpty) {
      throw NoModelConfiguredException('路由组「${group.name}」没有可用成员');
    }

    var candidates = allMembers;
    var requireVision = false;
    if (preferVision && group.preferVision) {
      final visionMembers = allMembers
          .where((c) => ModelVisionCapability.supportsVision(c))
          .toList();
      if (visionMembers.isNotEmpty) {
        candidates = visionMembers;
        requireVision = true;
      }
    }

    // 冷却成员不参与轮换/权重/评分，全部冷却时退回「最早解锁」再让发信层排队等待
    var selectable =
        candidates.where((c) => !isCooling(_key(c))).toList();
    if (selectable.isEmpty) {
      selectable = candidates;
      LoggerService.instance.logAI(
        '路由组「${group.name}」全部成员冷却中，按最早解锁成员发出（由 Key 池排队）',
        level: LogLevel.warning,
      );
    }

    final ordered =
        _orderedCandidates(group, selectable, advance: advance);
    final selected = ordered.first;
    if (advance) {
      _lastUsed[group.id] = _key(selected);
      LoggerService.instance.logAI(
        '路由组「${group.name}」策略=${group.strategy.label} '
        '本次选择 ${ordered.indexOf(selected) + 1}/${ordered.length}：'
        '${selected.providerId} · ${selected.modelName}',
      );
    }
    return AiRouteSelection(
      config: selected,
      candidates: ordered,
      group: group,
      requireVision: requireVision,
    );
  }

  /// 组内可解析的成员（厂存在且未停用 + 模型仍启用 + 地址与密钥齐全）→ 请求配置
  List<AiConfig> _feasibleMembers(AiRouteGroup group, List<AiProvider> providers) {
    final result = <AiConfig>[];
    for (final member in group.enabledMembers) {
      final provider =
          providers.where((p) => p.id == member.providerId).firstOrNull;
      if (provider == null) continue;
      // 厂商被停用时整条成员让位，组里其它厂商的成员继续承接流量
      if (!provider.enabled) continue;
      if (!provider.hasModel(member.modelName)) continue;
      if (provider.baseUrl.trim().isEmpty) continue;
      if (!provider.hasCredentials) continue;
      result.add(AiConfig.fromProvider(provider, member.modelName));
    }
    return result;
  }

  /// 按策略给出候选顺序：首位是本次要用的成员，其余是失败后的切换顺序
  ///
  /// [advance] 为 false 时只计算「当前轮到谁」而不推进任何轮询状态。
  List<AiConfig> _orderedCandidates(
    AiRouteGroup group,
    List<AiConfig> selectable, {
    required bool advance,
  }) {
    switch (group.strategy) {
      case RouteStrategy.manual:
        final pinned = group.pinnedMember;
        final index = pinned == null
            ? -1
            : selectable.indexWhere((c) => _key(c) == pinned);
        final start = index >= 0 ? index : 0;
        return _rotateOrder(selectable, start);
      case RouteStrategy.failover:
        // 顺序策略的优先级 = 成员顺序，且始终从第一个可用成员开始
        return _rotateOrder(selectable, 0);
      case RouteStrategy.weight:
        final start = _weightedStartIndex(group, selectable, advance: advance);
        return _rotateOrder(selectable, start);
      case RouteStrategy.smart:
        final sorted = List<AiConfig>.from(selectable)
          ..sort((a, b) => _smartScore(b, selectable).compareTo(
                _smartScore(a, selectable),
              ));
        return _rotateOrder(sorted, 0);
      case RouteStrategy.rotate:
        final cursor = _rotateCursor[group.id] ?? 0;
        final start = cursor % selectable.length;
        if (advance) {
          _rotateCursor[group.id] = (start + 1) % selectable.length;
        }
        return _rotateOrder(selectable, start);
    }
  }

  /// 以 [start] 为首位、其余按原顺序首尾相接（保持权重/智能排好的相对次序）
  List<AiConfig> _rotateOrder(List<AiConfig> source, int start) {
    if (source.length <= 1) return List<AiConfig>.from(source);
    final index = start % source.length;
    return [...source.sublist(index), ...source.sublist(0, index)];
  }

  /// 平滑加权轮询的起始成员（NGINX smooth WRR）
  ///
  /// 用「每轮给各成员按其权重累加、取最大者、被选中的减去总权重」而不是按区间抽样：
  /// 权重 3:1 时得到 A A B A 这样的均匀分布，短期内就贴近比例，
  /// 而不是先连续用 A 三次再轮到 B。
  ///
  /// [advance] 为 false 时只看这一轮会选谁，不改动累计权重。
  int _weightedStartIndex(
    AiRouteGroup group,
    List<AiConfig> selectable, {
    required bool advance,
  }) {
    if (selectable.length <= 1) return 0;
    final weights = selectable
        .map((c) => _weightFor(group, c)
            .clamp(RouteGroupMember.minWeight, RouteGroupMember.maxWeight))
        .toList();
    final total = weights.fold<int>(0, (a, b) => a + b);

    var best = 0;
    int? bestCurrent;
    for (var i = 0; i < selectable.length; i++) {
      final key = _weightKey(group.id, selectable[i]);
      final current = (_weightCurrent[key] ?? 0) + weights[i];
      if (advance) _weightCurrent[key] = current;
      // 平局取靠前成员：3:1 时第二轮的平局落在第一个成员上，得到 A A B A
      if (bestCurrent == null || current > bestCurrent) {
        bestCurrent = current;
        best = i;
      }
    }
    if (advance) {
      final bestKey = _weightKey(group.id, selectable[best]);
      _weightCurrent[bestKey] = (_weightCurrent[bestKey] ?? 0) - total;
    }
    return best;
  }

  String _weightKey(String groupId, AiConfig config) =>
      '$groupId|${_key(config)}';

  int _weightFor(AiRouteGroup group, AiConfig config) {
    for (final member in group.members) {
      if (member.providerId == config.providerId &&
          member.modelName == config.modelName) {
        return member.weight;
      }
    }
    return RouteGroupMember.minWeight;
  }

  /// 智能策略打分：近期成功率为主，其次响应耗时，最后用「用得少」微调均衡
  double _smartScore(AiConfig config, List<AiConfig> selectable) {
    final health = _health[_key(config)];
    final successRate = health?.successRate ?? 1.0;
    final latency = health?.latencyEwmaMs;
    final double latencyScore;
    if (latency == null) {
      latencyScore = 1.0;
    } else {
      final normalized =
          latency.clamp(0.0, latencyCeilingMs.toDouble()) / latencyCeilingMs;
      latencyScore = (1 - normalized).clamp(0.0, 1.0).toDouble();
    }
    final maxUses = selectable
        .map((c) => _health[_key(c)]?.uses ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final uses = health?.uses ?? 0;
    final usageScore = maxUses == 0 ? 1.0 : 1 - (uses / (maxUses + 1));
    return successRate * 0.6 + latencyScore * 0.3 + usageScore * 0.1;
  }

  Duration _cooldownFor(Object error) {
    var cooldown = memberCooldown;
    if (ApiKeyPool.isKeyScopedError(error)) {
      cooldown = ApiKeyPool.instance.cooldownFromError(error);
    } else if (ApiKeyPool.isConnectionClassError(error) ||
        _isServerError(error)) {
      cooldown = transientCooldown;
    }
    return cooldown > maxCooldown ? maxCooldown : cooldown;
  }

  bool _isServerError(Object error) {
    final status = error is DioException ? error.response?.statusCode : null;
    return status != null && status >= 500;
  }

  static String _key(AiConfig config) =>
      '${config.providerId}::${config.modelName}';

  @visibleForTesting
  void resetForTest() {
    _rotateCursor.clear();
    _weightCurrent.clear();
    _health.clear();
    _cooldownUntil.clear();
    _lastUsed.clear();
    _groupNames.clear();
  }
}
