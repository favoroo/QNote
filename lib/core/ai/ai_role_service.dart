import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/ai_route_service.dart';
import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/core/storage/ai_provider_repository.dart';
import 'package:qnote_flutter/core/storage/ai_route_group_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 角色解析结果：本次真正使用的模型配置，以及（绑定路由组时的）组内切换器
class AiRoleResolution {
  final AiConfig config;

  /// 绑定的是路由组时非 null，发信层据此在成员失败时切换到下一个成员
  final AiModelRoute? route;

  const AiRoleResolution({required this.config, this.route});
}

/// 判断一条绑定（具体模型或路由组）在当前配置下是否仍然有效
///
/// 与 [AiRoleService.resolveForRole] 同一套判据，供界面（胶囊展示、选择器、
/// 设置页角色行）复用：这些地方原本各自写了一遍 `provider.hasModel(...)`，
/// 漏掉路由组会让「绑了组但显示未配置」。
///
/// 厂商被手动停用时也算「当前无效」：界面会显示成跟随默认模型，真正发信时也
/// 确实不会用到它。绑定本身不被清理（见 [isBindingResolvable]）。
bool isBindingUsable(AiModelRef? ref, List<AiProvider> providers, List<AiRouteGroup> groups) {
  if (ref == null) return false;
  if (ref.isRouteGroup) {
    final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
    if (group == null) return false;
    return hasResolvableMember(group, providers);
  }
  final provider = providers.where((p) => p.id == ref.providerId).firstOrNull;
  return provider != null && provider.enabled && provider.hasModel(ref.modelName);
}

/// 绑定是否仍指向存在的厂商/组与模型（**忽略**厂商的停用开关）
///
/// 供「清理陈旧绑定」使用：停用厂商是临时动作，绑定要留到再次启用时复用，
/// 只有厂商/组被删、或模型被逐条停用才算真的失效。
bool isBindingResolvable(AiModelRef? ref, List<AiProvider> providers, List<AiRouteGroup> groups) {
  if (ref == null) return false;
  if (ref.isRouteGroup) {
    final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
    if (group == null) return false;
    for (final member in group.enabledMembers) {
      final provider = providers.where((p) => p.id == member.providerId).firstOrNull;
      if (provider != null && provider.hasModel(member.modelName)) return true;
    }
    return false;
  }
  final provider = providers.where((p) => p.id == ref.providerId).firstOrNull;
  return provider != null && provider.hasModel(ref.modelName);
}

/// 组内是否至少有一个「厂商存在（且未停用） + 模型仍启用」的成员
///
/// 只做结构性校验，不看冷却状态：冷却中的组仍是「配置有效」，只是暂时不用它。
bool hasResolvableMember(AiRouteGroup group, List<AiProvider> providers) {
  for (final member in group.enabledMembers) {
    final provider = providers.where((p) => p.id == member.providerId).firstOrNull;
    if (provider != null && provider.enabled && provider.hasModel(member.modelName)) {
      return true;
    }
  }
  return false;
}

/// 角色级的思考强度默认值
///
/// 时间线提取是结构化抽取：思考不会让字段更准，只会把单次提取拖长（新加的
/// 模型服务默认开思考，表现就是「点了提取很久没反应」）。因此该角色固定用
/// 尽可能低的档位：支持关闭的模型发「关闭」（OpenAI 兼容协议映射为 `minimal`），
/// 不支持关闭的模型退到它能力表里的最低档，避免把请求打挂。
///
/// 只覆盖「用时间线角色发信」的场景，模型级档位对其它角色（小Q 对话）仍然生效。
AiConfig applyRoleReasoningDefault(String role, AiConfig config) {
  if (role != 'timelineOptimization') {
    return config;
  }
  final capability = ModelReasoningCapability.forUi(
    modelName: config.modelName,
    providerType: config.provider,
    vendorId: config.vendorId,
    customLevels: config.reasoningEfforts,
  );
  return config.copyWith(
    reasoningEffort: capability.supports(ReasoningEffort.none)
        ? ReasoningEffort.none
        // 自定义档位可能裁掉了「低」，退到该模型可选的最低档而不是硬编码 low
        : capability.levels.first,
  );
}

/// 角色 → 厂商模型 / 路由组 的绑定与解析服务
///
/// 数据源有两处：`ai_providers` 厂商条目表与 `ai_route_groups` 路由组表。角色里存
/// [AiModelRef]（厂商 id + 模型名；路由组用 [AiModelRef.groupMarker] 哨兵），解析时
/// 组装请求用的 [AiConfig]；绑定是路由组时按组策略选出一个真实成员，并把
/// [AiModelRoute] 交给发信层做组内故障切换。绑定失效（厂商/组被删、模型被停用）时按
/// 「默认厂商的首个已启用模型 → 首个厂商的首个已启用模型」回落，全部落空则抛
/// [NoModelConfiguredException] 交给 UI 引导。
class AiRoleService {
  static final AiRoleService _instance = AiRoleService._();
  static AiRoleService get instance => _instance;
  AiRoleService._();

  final ConfigRepository _repo = ConfigRepository.instance;
  final AiProviderRepository _providers = AiProviderRepository.instance;
  final AiRouteGroupRepository _groups = AiRouteGroupRepository.instance;

  /// AI 温度设置迁移版本标记
  static const _aiTempsMigrationVersionKey = 'ai_temps_migration_version';

  /// 初始化：只跑仍在生效的迁移，不再自动写入任何角色绑定
  ///
  /// 旧版本会在这里把两个角色默认指到内置免费模型（开箱即用）；内置模型下线后
  /// 「开箱即用」不再成立——没有厂商条目时由「未配置模型」引导弹窗负责把用户
  /// 带到添加页，因此这里刻意什么都不写。
  Future<void> initAndEnsureDefaults() async {
    await _migrateExtractImagesDefault();
  }

  /// 迁移旧版用户的 extractImages 设置：默认开启图片提取
  ///
  /// 历史问题：之前 timelineOptimization.extractImages 默认为 false，
  /// 导致用户上传图片后 AI 提取不会发送图片，表现为"图片提取失败"。
  /// 此迁移将已有用户的设置升级为 true，让图片提取开箱即用。
  Future<void> _migrateExtractImagesDefault() async {
    const currentVersion = 1;
    final prefs = await SharedPreferences.getInstance();
    final lastVersion = prefs.getInt(_aiTempsMigrationVersionKey) ?? 0;

    if (lastVersion >= currentVersion) return;

    final existingTemps = await _repo.getAiTemperatures();
    if (existingTemps == null) {
      // 新用户：默认值已经是 true，无需迁移，直接标记版本
      await prefs.setInt(_aiTempsMigrationVersionKey, currentVersion);
      return;
    }

    // 已有用户：如果 timelineOptimization.extractImages 为 false，升级为 true
    if (!existingTemps.timelineOptimization.extractImages) {
      final updated = existingTemps.copyWith(
        timelineOptimization: existingTemps.timelineOptimization.copyWith(extractImages: true),
      );
      await _repo.saveAiTemperatures(updated);
    }

    await prefs.setInt(_aiTempsMigrationVersionKey, currentVersion);
  }

  Future<AiRoles> getRoles() async {
    return await _repo.getAiRoles() ?? const AiRoles();
  }

  Future<void> saveRoles(AiRoles roles) async {
    await _repo.saveAiRoles(roles);
  }

  /// 清理指向已删除厂商 / 已停用模型 / 已删除路由组的角色绑定，返回清理后的角色配置
  ///
  /// 保留绑定会让界面显示的名字与实际生效模型不一致：解析侧虽有回落，
  /// 但用户看到的「已选模型」是失效项，必须把绑定归位到未绑定状态。
  ///
  /// 判据用 [isBindingResolvable] 而非 [isBindingUsable]：「停用厂商」是可逆动作，
  /// 绑定要留着，否则用户重新启用后还得再配一遍角色模型。
  Future<AiRoles> pruneStaleRoleBindings() async {
    final roles = await getRoles();
    final providers = await _providers.getAll();
    final groups = await _groups.getAll();

    var updated = roles;
    var changed = false;
    if (!isBindingResolvable(roles.assistant, providers, groups)) {
      updated = updated.copyWith(assistant: null);
      changed = true;
    }
    if (!isBindingResolvable(roles.timelineOptimization, providers, groups)) {
      updated = updated.copyWith(timelineOptimization: null);
      changed = true;
    }
    if (roles.imageGeneration != null && !isBindingResolvable(roles.imageGeneration, providers, groups)) {
      updated = updated.copyWith(imageGeneration: null);
      changed = true;
    }

    if (changed) {
      await saveRoles(updated);
    }
    return updated;
  }

  Future<AiTemperatures> getTemperatures() async {
    return await _repo.getAiTemperatures() ?? const AiTemperatures();
  }

  Future<void> saveTemperatures(AiTemperatures temps) async {
    await _repo.saveAiTemperatures(temps);
  }

  Future<AiRoleSettings> getSettingsForRole(String role) async {
    final temps = await getTemperatures();
    switch (role) {
      case 'assistant':
        return temps.assistant;
      case 'timelineOptimization':
        return temps.timelineOptimization;
      default:
        return const AiRoleSettings();
    }
  }

  Future<double> getTemperatureForRole(String role) async {
    final settings = await getSettingsForRole(role);
    return settings.temperature;
  }

  Future<int> getMaxTokensForRole(String role) async {
    final settings = await getSettingsForRole(role);
    return settings.maxTokens;
  }

  /// 取角色绑定的模型引用（未绑定返回 null）
  Future<AiModelRef?> boundRefForRole(String role) async {
    final roles = await getRoles();
    switch (role) {
      case 'assistant':
        return roles.assistant;
      case 'timelineOptimization':
        return roles.timelineOptimization;
      case 'imageGeneration':
        return roles.imageGeneration;
      default:
        return null;
    }
  }

  /// 写入角色绑定（null 表示清空绑定，回落到默认厂商的首个模型）
  Future<void> bindRole(String role, AiModelRef? ref) async {
    final roles = await getRoles();
    switch (role) {
      case 'assistant':
        await saveRoles(roles.copyWith(assistant: ref));
        break;
      case 'timelineOptimization':
        await saveRoles(roles.copyWith(timelineOptimization: ref));
        break;
      case 'imageGeneration':
        await saveRoles(roles.copyWith(imageGeneration: ref));
        break;
    }
  }

  /// 解析角色的有效配置与组内切换器；没有任何可用模型时抛 [NoModelConfiguredException]
  ///
  /// [preferVision] 表示本次请求是否带图片：为真时路由组优先选支持识图的成员
  /// （小Q 主对话/悬浮窗在构建上下文时已经知道本轮有没有图片）。
  Future<AiRoleResolution> resolveForRole(String role, {bool preferVision = false}) async {
    final providers = await _providers.getAll();
    final groups = await _groups.getAll();
    final ref = await boundRefForRole(role);

    final bound = _resolveRef(providers, groups, ref, preferVision: preferVision);
    if (bound != null) return bound;

    // 绑定缺失/失效：默认厂商的首个已启用模型 → 首个可用厂商的首个已启用模型
    final fallback = _firstUsableProvider(providers);
    if (fallback != null) {
      final model = fallback.firstModel!;
      return AiRoleResolution(config: AiConfig.fromProvider(fallback, model.id));
    }

    throw NoModelConfiguredException(role);
  }

  /// 解析角色的有效配置（不含组内切换器，供非流式单次调用使用）
  ///
  /// 会推进路由组的轮次：调用它就意味着「接下来要发一次请求」。
  /// 只想知道当前会用哪个模型、不发请求的场景请用 [peekConfigForRole]。
  Future<AiConfig> getEffectiveConfigForRole(String role) async {
    final config = (await resolveForRole(role)).config;
    return applyRoleReasoningDefault(role, config);
  }

  /// 只看「当前会轮到哪个模型」，不推进路由组轮次
  ///
  /// 给可用性预检与能力判定这类不发请求的调用方用：否则一次提问里的预检会把
  /// 轮次提前用掉，真正的请求落到别的成员上，用户会觉得「轮流没按预期走」。
  /// 无可用模型时返回 null（不抛异常）。
  Future<AiConfig?> peekConfigForRole(String role, {bool preferVision = false}) async {
    try {
      final providers = await _providers.getAll();
      final groups = await _groups.getAll();
      final ref = await boundRefForRole(role);
      final resolved = _resolveRef(providers, groups, ref, preferVision: preferVision, advance: false);
      if (resolved != null) return resolved.config;
      final fallback = _firstUsableProvider(providers);
      if (fallback == null) return null;
      return AiConfig.fromProvider(fallback, fallback.firstModel!.id);
    } catch (_) {
      return null;
    }
  }

  /// 预检：角色当前是否有可用模型（入口处弹引导用，失败不抛异常）
  Future<bool> hasUsableConfigForRole(String role) async {
    return await peekConfigForRole(role) != null;
  }

  /// 生图工具使用的配置；未配置生图模型时返回 null（工具据此给出引导文案）
  ///
  /// 刻意不回落默认对话模型：生图需要的是支持 `images/generations` 的模型，
  /// 拿一个对话模型顶上去只会得到一次必然失败的调用。绑定路由组时同样按组策略选成员。
  Future<AiConfig?> getImageGenerationConfig() async {
    final roles = await getRoles();
    final ref = roles.imageGeneration;
    if (ref == null) return null;
    final providers = await _providers.getAll();
    final groups = await _groups.getAll();
    return _resolveRef(providers, groups, ref)?.config;
  }

  /// 绑定引用 → 解析结果；具体模型 / 路由组 / 失效三种情况都在这里收敛
  ///
  /// 路由组解析失败（组被删、成员全失效）返回 null，交回调用方的回落路径——
  /// 与「绑定的模型被停用」是同一种语义，界面表现为「跟随默认」而不是报错。
  AiRoleResolution? _resolveRef(
    List<AiProvider> providers,
    List<AiRouteGroup> groups,
    AiModelRef? ref, {
    bool preferVision = false,
    bool advance = true,
  }) {
    if (ref == null) return null;

    if (ref.isRouteGroup) {
      final group = groups.where((g) => g.id == ref.providerId).firstOrNull;
      if (group == null) return null;
      try {
        final selection = AiRouteService.instance.select(
          group,
          providers,
          preferVision: preferVision,
          advance: advance,
        );
        return AiRoleResolution(config: selection.config, route: selection.toRoute());
      } on NoModelConfiguredException {
        return null;
      }
    }

    final provider = providers.where((p) => p.id == ref.providerId).firstOrNull;
    if (provider == null) return null;
    // 已停用的厂商等同于「当前没有这个模型」：绑定保留，但请求回落到默认厂商
    if (!provider.enabled) return null;
    if (!provider.hasModel(ref.modelName)) return null;
    if (provider.baseUrl.trim().isEmpty) return null;
    if (!provider.hasCredentials) return null;
    return AiRoleResolution(config: AiConfig.fromProvider(provider, ref.modelName));
  }

  /// 默认厂商优先，其次按创建顺序取第一个「地址 + 密钥 + 模型」齐全的厂商
  AiProvider? _firstUsableProvider(List<AiProvider> providers) {
    for (final provider in providers) {
      if (provider.isDefault && provider.isUsable) return provider;
    }
    for (final provider in providers) {
      if (provider.isUsable) return provider;
    }
    return null;
  }
}
