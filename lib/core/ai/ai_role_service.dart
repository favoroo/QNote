import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/free_model_config.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AiRoleService {
  static final AiRoleService _instance = AiRoleService._();
  static AiRoleService get instance => _instance;
  AiRoleService._();

  final ConfigRepository _repo = ConfigRepository.instance;

  // 免费模型主模型选择持久化键
  static const _selectedFreeModelKey = 'selected_free_model';
  // AI 温度设置迁移版本标记
  static const _aiTempsMigrationVersionKey = 'ai_temps_migration_version';

  /// 初始化并确保默认配置
  Future<void> initAndEnsureDefaults() async {
    final existing = await _repo.getAiRoles();
    if (existing == null) {
      // 初次进入应用：自动配置使用免费模型
      await saveRoles(
        const AiRoles(
          assistantUseFreeModel: true,
          timelineOptimizationUseFreeModel: true,
        ),
      );

      // 自动刷新（拉取）免费模型列表，不阻塞 UI
      FreeModelService.instance.fetchRemoteManifest().catchError((e) {
        return FreeModelsManifest(models: [], updatedAt: DateTime.now());
      });
    } else {
      // 如果已有配置，但缓存为空，也静默拉取一次
      final cached = await FreeModelService.instance.getCachedModels();
      if (cached.isEmpty) {
        FreeModelService.instance.fetchRemoteManifest().catchError((e) {
          return FreeModelsManifest(models: [], updatedAt: DateTime.now());
        });
      }
    }

    // 迁移：将 timelineOptimization.extractImages 默认值从 false 升级为 true
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

  Future<AiTemperatures> getTemperatures() async {
    return await _repo.getAiTemperatures() ?? const AiTemperatures();
  }

  Future<void> saveTemperatures(AiTemperatures temps) async {
    await _repo.saveAiTemperatures(temps);
  }

  Future<AiConfig?> getConfigForRole(String role) async {
    final roles = await getRoles();
    String? configId;
    switch (role) {
      case 'assistant':
        configId = roles.assistant;
        break;
      case 'timelineOptimization':
        configId = roles.timelineOptimization;
        break;
    }
    if (configId == null) return null;
    final configs = await _repo.getAllAiConfigs();
    try {
      return configs.firstWhere((c) => c.id == configId);
    } catch (_) {
      return null;
    }
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

  /// 判断角色是否启用了免费模型
  Future<bool> isFreeModelEnabled(String role) async {
    final roles = await getRoles();
    if (role == 'assistant') return roles.assistantUseFreeModel;
    if (role == 'timelineOptimization') {
      return roles.timelineOptimizationUseFreeModel;
    }
    return false;
  }

  /// 获取用户选择的主模型ID
  Future<String?> getPreferredFreeModelId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedFreeModelKey);
  }

  /// 保存用户选择的主模型ID
  Future<void> savePreferredFreeModelId(String? modelId) async {
    final prefs = await SharedPreferences.getInstance();
    if (modelId == null || modelId.isEmpty) {
      await prefs.remove(_selectedFreeModelKey);
    } else {
      await prefs.setString(_selectedFreeModelKey, modelId);
    }
  }

  /// 获取角色绑定的免费模型列表（排序后）
  Future<List<FreeModelConfig>> getFreeModelConfigsForRole(String role) async {
    final models = await FreeModelService.instance.getCachedModels();
    if (models.isEmpty) return [];
    final preferredId = await getPreferredFreeModelId();
    return FreeModelService.instance.getOrderedModels(models, preferredId);
  }

  /// 获取角色的有效配置
  ///
  /// 如果角色启用了免费模型，返回主模型的 AiConfig；
  /// 否则走原有逻辑（角色绑定 → 默认配置 → 第一个配置）。
  Future<AiConfig> getEffectiveConfigForRole(String role) async {
    final roles = await getRoles();

    // 检查角色是否启用免费模型
    final useFreeModel = role == 'assistant'
        ? roles.assistantUseFreeModel
        : roles.timelineOptimizationUseFreeModel;

    if (useFreeModel) {
      final models = await FreeModelService.instance.getCachedModels();
      if (models.isEmpty) {
        throw Exception('免费模型列表为空，请先在设置中更新免费模型');
      }
      final preferredId = await getPreferredFreeModelId();
      final ordered = FreeModelService.instance.getOrderedModels(
        models,
        preferredId,
      );
      return FreeModelService.instance.toAiConfig(ordered.first);
    }

    // 原有逻辑
    final roleConfig = await getConfigForRole(role);
    if (roleConfig != null) return roleConfig;
    final configs = await _repo.getAllAiConfigs();
    final defaultConfig = configs.where((c) => c.isDefault).firstOrNull;
    if (defaultConfig != null) return defaultConfig;
    if (configs.isNotEmpty) return configs.first;
    throw Exception('No AI config available');
  }
}
