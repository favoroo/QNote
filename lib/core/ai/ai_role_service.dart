import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/no_model_exception.dart';
import 'package:qnote_flutter/core/storage/ai_provider_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

/// 角色 → 厂商模型 的绑定与解析服务
///
/// 数据源只有一处：`ai_providers` 厂商条目表。角色里存 [AiModelRef]
/// （厂商 id + 模型名），解析时组装请求用的 [AiConfig]；绑定失效
/// （厂商被删、模型被停用）时按「默认厂商的首个已启用模型 → 首个厂商的首个
/// 已启用模型」回落，全部落空则抛 [NoModelConfiguredException] 交给 UI 引导。
class AiRoleService {
  static final AiRoleService _instance = AiRoleService._();
  static AiRoleService get instance => _instance;
  AiRoleService._();

  final ConfigRepository _repo = ConfigRepository.instance;
  final AiProviderRepository _providers = AiProviderRepository.instance;

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
        timelineOptimization:
            existingTemps.timelineOptimization.copyWith(extractImages: true),
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

  /// 清理指向已删除厂商 / 已停用模型的角色绑定，返回清理后的角色配置
  ///
  /// 保留绑定会让界面显示的名字与实际生效模型不一致：解析侧虽有回落，
  /// 但用户看到的「已选模型」是失效项，必须把绑定归位到未绑定状态。
  Future<AiRoles> pruneStaleRoleBindings() async {
    final roles = await getRoles();
    final providers = await _providers.getAll();

    bool isValid(AiModelRef? ref) {
      if (ref == null) return true;
      final provider =
          providers.where((p) => p.id == ref.providerId).firstOrNull;
      return provider != null && provider.hasModel(ref.modelName);
    }

    var updated = roles;
    var changed = false;
    if (!isValid(roles.assistant)) {
      updated = updated.copyWith(assistant: null);
      changed = true;
    }
    if (!isValid(roles.timelineOptimization)) {
      updated = updated.copyWith(timelineOptimization: null);
      changed = true;
    }
    if (!isValid(roles.imageGeneration)) {
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

  /// 解析角色的有效配置；没有任何可用模型时抛 [NoModelConfiguredException]
  Future<AiConfig> getEffectiveConfigForRole(String role) async {
    final providers = await _providers.getAll();
    final ref = await boundRefForRole(role);

    final bound = _resolveRef(providers, ref);
    if (bound != null) return bound;

    // 绑定缺失/失效：默认厂商的首个已启用模型 → 首个可用厂商的首个已启用模型
    final fallback = _firstUsableProvider(providers);
    if (fallback != null) {
      final model = fallback.firstModel!;
      return AiConfig.fromProvider(fallback, model.id);
    }

    throw NoModelConfiguredException(role);
  }

  /// 预检：角色当前是否有可用模型（入口处弹引导用，失败不抛异常）
  Future<bool> hasUsableConfigForRole(String role) async {
    try {
      final providers = await _providers.getAll();
      final ref = await boundRefForRole(role);
      if (_resolveRef(providers, ref) != null) return true;
      return _firstUsableProvider(providers) != null;
    } catch (_) {
      return false;
    }
  }

  /// 生图工具使用的配置；未配置生图模型时返回 null（工具据此给出引导文案）
  ///
  /// 刻意不回落默认对话模型：生图需要的是支持 `images/generations` 的模型，
  /// 拿一个对话模型顶上去只会得到一次必然失败的调用。
  Future<AiConfig?> getImageGenerationConfig() async {
    final roles = await getRoles();
    final ref = roles.imageGeneration;
    if (ref == null) return null;
    final providers = await _providers.getAll();
    return _resolveRef(providers, ref);
  }

  /// 厂商条目 + 模型引用 → 请求配置；厂商/模型/密钥/地址任一不可用返回 null
  AiConfig? _resolveRef(List<AiProvider> providers, AiModelRef? ref) {
    if (ref == null) return null;
    final provider =
        providers.where((p) => p.id == ref.providerId).firstOrNull;
    if (provider == null) return null;
    if (!provider.hasModel(ref.modelName)) return null;
    if (provider.baseUrl.trim().isEmpty) return null;
    if (!provider.apiKeys.any((key) => key.trim().isNotEmpty)) return null;
    return AiConfig.fromProvider(provider, ref.modelName);
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