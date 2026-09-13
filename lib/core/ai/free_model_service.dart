import 'dart:async';
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
  FreeModelService._() {
    _registerEndpointRefresher();
  }

  // jsDelivr 加速（国内友好）+ GitHub raw 回退
  static const _jsdelivrUrl =
      'https://cdn.jsdelivr.net/gh/favoroo/QNote@main/free_models.json';
  static const _githubRawUrl =
      'https://raw.githubusercontent.com/favoroo/QNote/main/free_models.json';

  // 动态 CPA 端点同步地址（个人主页静态资源 + jsDelivr 加速）
  static const List<String> _dynamicCpaEndpoints = [
    'https://favoroo.github.io/Q-profile/api-endpoint.json',
    'https://cdn.jsdelivr.net/gh/favoroo/Q-profile@main/public/api-endpoint.json',
    'https://raw.githubusercontent.com/favoroo/Q-profile/main/public/api-endpoint.json',
  ];

  // SharedPreferences 缓存键
  static const _cacheKey = 'free_models_cache';
  static const _lastUpdateKey = 'free_models_last_update';
  static const _dynamicBaseUrlCacheKey = 'cpa_dynamic_base_url';
  static const _dynamicFallbackCacheKey = 'cpa_dynamic_fallback_base_url';

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

  /// 从云端拉取最新的动态 CPA 公网端点（优先使用 Cloudflare 极速地址，失败时静默回退）
  ///
  /// 成功后同时应用 primary 与 fallback（若云端提供且不同于 primary）到内存
  /// 静态变量，并持久化到 SharedPreferences；返回 primary 地址，三级源全部
  /// 失败或载荷无效时返回 null（保留当前/缓存值兜底）。
  Future<String?> fetchDynamicCpaEndpoint() async {
    for (final url in _dynamicCpaEndpoints) {
      try {
        final response = await _dio.get<dynamic>(
          url,
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        final parsed = parseCpaEndpointPayload(response.data);
        if (parsed != null) {
          BuiltinFreeKeys.updateDynamicCpaBaseUrl(parsed.primary);
          BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl(parsed.fallback);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_dynamicBaseUrlCacheKey, parsed.primary);
          await prefs.setString(
            _dynamicFallbackCacheKey,
            parsed.fallback ?? '',
          );
          LoggerService.instance.logAI(
            'CPA 动态端点拉取成功',
            details: '有效URL=${parsed.primary}'
                '${parsed.fallback != null ? ', 备用URL=${parsed.fallback}' : ''}'
                ', 来源=$url',
          );
          return parsed.primary;
        }
        LoggerService.instance.logAI(
          'CPA 动态端点载荷无有效地址: $url',
          level: LogLevel.warning,
        );
      } catch (e) {
        LoggerService.instance.logAI(
          '尝试拉取 CPA 动态端点失败: $url',
          details: e.toString(),
          level: LogLevel.warning,
        );
      }
    }
    return null;
  }

  /// 解析端点 JSON 载荷为 (primary, fallback) 地址对
  ///
  /// primary 缺失或无效时返回 null；fallback 缺失、与 primary 相同或无效时
  /// 为 null。URL 仅接受 https 明文地址（与请求端 updateConfig 的校验口径
  /// 一致）：云端 JSON 一旦被污染，明文 http 地址会带着内置 API Key 一起
  /// 泄露给任意主机，必须在此拦截。
  static CpaEndpointPair? parseCpaEndpointPayload(dynamic payload) {
    Map<String, dynamic>? data;
    if (payload is Map) {
      data = Map<String, dynamic>.from(payload);
    } else if (payload is String) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) data = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    if (data == null) return null;
    final primary = _sanitizeEndpointUrl(data['primary_base_url']);
    if (primary == null) return null;
    final fallback = _sanitizeEndpointUrl(data['fallback_base_url']);
    return CpaEndpointPair(
      primary: primary,
      fallback: fallback == primary ? null : fallback,
    );
  }

  /// 校验并归一化单个端点 URL：合法 https 地址且 host 非空，去除尾部斜杠
  static String? _sanitizeEndpointUrl(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty || raw.length > 500) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  /// 注册 AiService 的动态端点刷新钩子
  ///
  /// AiService 不反向依赖本类（避免循环 import），故以静态回调注入：
  /// 连接类瞬时故障重试前由 AiService 调用，拉取云端最新端点并在
  /// primary/fallback 与当前地址不同时返回新地址完成切换。
  void _registerEndpointRefresher() {
    AiService.dynamicEndpointRefresher = (currentBaseUrl) async {
      // 仅当故障端点属于动态 CPA 家族（primary/fallback/兜底 Tailscale 地址）
      // 时才参与刷新，用户自定义端点与 SenseNova 官方网关不受影响
      final family = <String>{
        BuiltinFreeKeys.defaultTailscaleBaseUrl,
        if (BuiltinFreeKeys.dynamicCpaBaseUrl.isNotEmpty)
          BuiltinFreeKeys.dynamicCpaBaseUrl,
        if (BuiltinFreeKeys.dynamicCpaFallbackBaseUrl.isNotEmpty)
          BuiltinFreeKeys.dynamicCpaFallbackBaseUrl,
      };
      if (!family.contains(currentBaseUrl)) return null;

      await fetchDynamicCpaEndpoint();
      final primary = BuiltinFreeKeys.dynamicCpaBaseUrl;
      if (primary.isNotEmpty && primary != currentBaseUrl) {
        return primary;
      }
      final fallback = BuiltinFreeKeys.dynamicCpaFallbackBaseUrl;
      if (fallback.isNotEmpty && fallback != currentBaseUrl) {
        return fallback;
      }
      return null;
    };
  }

  /// 获取内置模型列表（包含 Claude Sonnet 4.6、Gemini 3.5 Flash Lite、Gemini 3.8 Flash Low、SenseNova 6.8、GLM 5.2、DeepSeek V4 Flash）
  Future<List<FreeModelConfig>> getCachedModels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedUrl = prefs.getString(_dynamicBaseUrlCacheKey);
      if (cachedUrl != null && cachedUrl.isNotEmpty) {
        BuiltinFreeKeys.updateDynamicCpaBaseUrl(cachedUrl);
      }
      final cachedFallback = prefs.getString(_dynamicFallbackCacheKey);
      if (cachedFallback != null) {
        BuiltinFreeKeys.updateDynamicCpaFallbackBaseUrl(cachedFallback);
      }
      // 触发一次后台轻量异步探测更新（不阻塞当前返回）
      unawaited(fetchDynamicCpaEndpoint());
    } catch (_) {}

    return [
      BuiltinFreeKeys.createClaudeSonnet46Config(),
      BuiltinFreeKeys.createGemini35Config(),
      BuiltinFreeKeys.createGemini38Config(),
      BuiltinFreeKeys.createDefaultConfig(),
      BuiltinFreeKeys.createGlmConfig(),
      BuiltinFreeKeys.createDeepSeekConfig(),
    ];
  }

  /// 获取内置生图模型列表（专供小Q generate_image 工具与角色绑定使用）
  ///
  /// 刻意不并入 [getCachedModels]：生图模型不能出现在聊天模型选择器与
  /// 对话 fallback 链中（文本对话端点不支持图片输出模型）。
  List<FreeModelConfig> getImageGenerationModels() {
    return [
      BuiltinFreeKeys.createGemini31ImageConfig(),
      BuiltinFreeKeys.createSenseNovaU15ImageConfig(),
    ];
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
    // SenseNova 网关下的内置模型共享 4 个商汤轮询 Key
    final isSenseNovaBuiltinKey = model.id.contains('sensenova') ||
        model.id == 'glm-5.2' ||
        model.id == 'deepseek-v4-flash';
    // Gemini 专用网关的内置模型（含 Claude Sonnet 4.6 与生图模型 gemini-3.1-flash-image）
    final isGeminiBuiltinKey = model.id == 'claude-sonnet-4-6' ||
        model.id == 'gemini-3.8-flash-low' ||
        model.id == 'gemini-3.5-flash-lite' ||
        model.id == 'gemini-3.1-flash-image';

    final String effectiveKey;
    if (explicitApiKey != null && explicitApiKey.isNotEmpty) {
      effectiveKey = explicitApiKey;
    } else if (isSenseNovaBuiltinKey) {
      effectiveKey = FreeModelKeyManager.instance.acquireNextKey();
    } else if (isGeminiBuiltinKey) {
      effectiveKey = BuiltinFreeKeys.getGeminiApiKey();
    } else {
      effectiveKey = model.apiKey;
    }

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

/// 动态端点 JSON 的解析结果
///
/// [primary] 必有（已通过 https/host 校验），[fallback] 为云端备用地址，
/// 缺失、无效或与 primary 相同时为 null。
class CpaEndpointPair {
  final String primary;
  final String? fallback;

  const CpaEndpointPair({required this.primary, this.fallback});
}
