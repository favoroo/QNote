import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/builtin_free_keys.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/free_model_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 免费模型服务
///
/// 负责从远程（jsDelivr 加速，GitHub raw 回退）拉取免费模型清单，
/// 本地缓存，以及将 FreeModelConfig 转换为 AiConfig 供 AiService 使用。
class FreeModelService {
  static final FreeModelService _instance = FreeModelService._();
  static FreeModelService get instance => _instance;
  FreeModelService._();

  // jsDelivr 加速（国内友好）+ GitHub raw 回退
  static const _jsdelivrUrl =
      'https://cdn.jsdelivr.net/gh/favoroo/QNote@main/free_models.json';
  static const _githubRawUrl =
      'https://raw.githubusercontent.com/favoroo/QNote/main/free_models.json';

  // SharedPreferences 缓存键
  static const _cacheKey = 'free_models_cache';
  static const _lastUpdateKey = 'free_models_last_update';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  /// 从远程拉取免费模型清单
  ///
  /// jsDelivr 优先，失败回退 GitHub raw。成功后缓存到本地。
  Future<FreeModelsManifest> fetchRemoteManifest() async {
    Object? lastError;
    for (final url in [_jsdelivrUrl, _githubRawUrl]) {
      try {
        LoggerService.instance.logAI('拉取免费模型清单: $url');
        final response = await _dio.get<dynamic>(url);
        final jsonStr = response.data is String
            ? response.data as String
            : jsonEncode(response.data);
        final manifest = FreeModelsManifest.fromJson(jsonStr);
        if (manifest.models.isEmpty) {
          lastError = Exception('远程清单为空: $url');
          continue;
        }
        await _cacheManifest(manifest);
        LoggerService.instance.logAI(
          '免费模型清单更新成功',
          details: '模型数=${manifest.models.length}, 来源=$url',
        );
        return manifest;
      } catch (e) {
        lastError = e;
        LoggerService.instance.logAI(
          '拉取免费模型清单失败: $url',
          details: e.toString(),
          level: LogLevel.warning,
        );
        continue;
      }
    }
    throw Exception('拉取免费模型清单失败: $lastError');
  }

  /// 获取内置模型列表（直接使用加密内置的 SenseNova 6.8 配置，杜绝远端配置干扰）
  Future<List<FreeModelConfig>> getCachedModels() async {
    return [BuiltinFreeKeys.createDefaultConfig()];
  }

  /// 规范化并迁移清单中的模型（修复旧版下线模型名称，如 6.7 迁移为 6.8）
  FreeModelsManifest _migrateManifest(FreeModelsManifest manifest) {
    bool hasChanges = false;
    final migratedModels = manifest.models.map((m) {
      final normalizedModelName = AiService.normalizeModelName(m.modelName, baseUrl: m.baseUrl);
      if (normalizedModelName != m.modelName) {
        hasChanges = true;
        return m.copyWith(modelName: normalizedModelName);
      }
      return m;
    }).toList();

    if (!hasChanges) return manifest;

    return FreeModelsManifest(
      version: manifest.version,
      updatedAt: manifest.updatedAt,
      models: migratedModels,
    );
  }

  /// 获取本地缓存的清单元数据（默认回退内置数据）
  Future<FreeModelsManifest?> getCachedManifest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_cacheKey);
      if (jsonStr == null || jsonStr.isEmpty) {
        // 内置默认清单，保证打包 APK 后离线开箱即用
        return FreeModelsManifest(
          version: '1.0',
          updatedAt: DateTime.now(),
          models: [BuiltinFreeKeys.createDefaultConfig()],
        );
      }
      final parsed = FreeModelsManifest.fromJson(jsonStr);
      final migrated = _migrateManifest(parsed);
      // 若缓存中存在旧模型（如 sensenova-6.7），自动写回升级后的缓存
      if (migrated != parsed) {
        await prefs.setString(_cacheKey, migrated.toJson());
      }
      return migrated;
    } catch (e) {
      LoggerService.instance.logAI(
        '读取免费模型缓存失败，使用内置配置',
        details: e.toString(),
        level: LogLevel.warning,
      );
      return FreeModelsManifest(
        version: '1.0',
        updatedAt: DateTime.now(),
        models: [BuiltinFreeKeys.createDefaultConfig()],
      );
    }
  }

  /// 获取最后更新时间
  Future<DateTime?> getLastUpdateTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_lastUpdateKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 保存清单到本地缓存
  Future<void> _cacheManifest(FreeModelsManifest manifest) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, manifest.toJson());
    await prefs.setInt(
        _lastUpdateKey, DateTime.now().millisecondsSinceEpoch);
    // 将清单中的有效 Key 融合进 KeyManager
    final keys = manifest.models.map((m) => m.apiKey).where((k) => k.isNotEmpty).toList();
    FreeModelKeyManager.instance.updateKeys(keys);
  }

  /// 将 FreeModelConfig 转换为 AiConfig（供 AiService 使用）
  ///
  /// 支持从 FreeModelKeyManager 自动进行轮询取 Key，并支持指定特定 Key 重试
  AiConfig toAiConfig(FreeModelConfig model, {String? explicitApiKey}) {
    final now = DateTime.now();
    final effectiveKey = explicitApiKey ??
        (model.id.contains('sensenova')
            ? FreeModelKeyManager.instance.acquireNextKey()
            : model.apiKey);

    return AiConfig(
      id: 'free_${model.id}',
      name: model.displayName,
      provider: model.provider,
      modelName: model.modelName,
      apiKey: effectiveKey,
      baseUrl: model.baseUrl,
      vendorId: 'free_model',
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 获取排序后的模型列表
  ///
  /// 用户选的 preferredId 排第一，其余按 priority 升序排列。
  List<FreeModelConfig> getOrderedModels(
    List<FreeModelConfig> models,
    String? preferredId,
  ) {
    if (models.isEmpty) return [];
    final sorted = List<FreeModelConfig>.from(models)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    if (preferredId == null || preferredId.isEmpty) return sorted;
    final preferred =
        sorted.where((m) => m.id == preferredId).toList();
    if (preferred.isEmpty) return sorted;
    final rest = sorted.where((m) => m.id != preferredId).toList();
    return [...preferred, ...rest];
  }
}
