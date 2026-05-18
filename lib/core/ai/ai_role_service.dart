import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';

class AiRoleService {
  static final AiRoleService _instance = AiRoleService._();
  static AiRoleService get instance => _instance;
  AiRoleService._();

  final ConfigRepository _repo = ConfigRepository.instance;

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
      case 'imageExtraction':
        configId = roles.imageExtraction;
        break;
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
      case 'imageExtraction':
        return temps.imageExtraction;
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

  Future<AiConfig> getEffectiveConfigForRole(String role) async {
    final roleConfig = await getConfigForRole(role);
    if (roleConfig != null) return roleConfig;
    final configs = await _repo.getAllAiConfigs();
    final defaultConfig = configs.where((c) => c.isDefault).firstOrNull;
    if (defaultConfig != null) return defaultConfig;
    if (configs.isNotEmpty) return configs.first;
    throw Exception('No AI config available');
  }
}
