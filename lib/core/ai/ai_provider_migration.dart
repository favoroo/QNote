import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/config/models.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/ai_provider_repository.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_roles.dart';

/// 一次性数据迁移：模型级 `ai_configs` → 厂商级 `ai_providers`
///
/// 旧模型是「一个模型一行」，新模型是「一个厂商一条：一个地址 + 一组 Key +
/// 一组已启用模型」。迁移按 `(vendorId, baseUrl, 接口类型)` 分组归并：
/// Key 去重合并成池、模型并入启用列表、旧默认行决定默认厂商，角色绑定
/// （configId）改写为 `AiModelRef(providerId, modelName)`。
///
/// 与内置模型下线同步进行：旧角色里指向内置免费模型的字段（`useFreeModel` /
/// `freeModelId` 等）本来就会被新 `AiRoles.fromMap` 忽略，裸配置 id 解析成
/// `AiModelRef` 失败时同样按「未绑定」回落，因此这里只需要处理真实存在的行。
class AiProviderMigration {
  AiProviderMigration._();

  static final AiProviderMigration instance = AiProviderMigration._();

  /// 迁移标记（标记位含 v1：以后再有结构性迁移就 +1 另写一段）
  static const String _prefsFlag = 'ai_provider_migration_v1';

  /// SP 里需要清掉的免费模型时代遗留键（精确键）
  ///
  /// 刻意不含 `ai_temps_migration_version`：那是仍在生效的温度/图片提取迁移标记，
  /// 清掉会让「已手动关闭图片提取」的用户被重新强制打开。
  static const List<String> _legacyPrefKeys = [
    'selected_free_model',
    'default_model_migration_v5',
  ];

  /// SP 里需要清掉的免费模型时代遗留键（前缀匹配）
  static const List<String> _legacyPrefPrefixes = [
    'last_api_key_',
    'fetched_models_',
    'free_models_',
    'cpa_',
    'ai_latency_',
    'batch_latency_',
    'openrouter_free_models',
    'chatanywhere_models',
  ];

  Future<void> run() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefsFlag) == true) return;

    try {
      final rows = await _readLegacyRows();
      final migrated = await migrateLegacyConfigRows(rows);
      if (migrated) {
        await _cleanLegacyPrefs(prefs);
      }
    } catch (e, st) {
      // 迁移失败不阻断启动：数据还在旧表里，下一次启动会重试（标记位不写）
      LoggerService.instance.logAI(
        '厂商条目迁移失败，将在下次启动重试',
        details: '$e\n$st',
        level: LogLevel.error,
      );
      return;
    }

    await prefs.setBool(_prefsFlag, true);
  }

  /// 供单测与「导入旧格式备份」复用的迁移核心：把旧行归并为厂商条目并改写角色绑定
  ///
  /// 返回是否真的发生了迁移；[deleteLegacyRows] 为 false 时不清空本地旧行
  /// （导入旧备份的场景旧行本来就不来自本地表）。
  Future<bool> migrateLegacyConfigRows(
    List<Map<String, dynamic>> rows, {
    bool deleteLegacyRows = true,
  }) async {
    if (rows.isEmpty) {
      // 无旧数据也要尝试改写角色：老用户可能只有内置模型绑定（useFreeModel）
      return _migrateRoles(const {});
    }

    final repo = AiProviderRepository.instance;
    final providers = AiProvider.fromLegacyConfigMaps(rows);
    final configIdToRef = <String, AiModelRef>{};

    for (final provider in providers) {
      final resolvedId = provider.id.isEmpty ? const Uuid().v4() : provider.id;
      // 展示名优先取厂商模板名（'deepseek' → 'DeepSeek'），自定义地址保持原样
      final vendorName = getProviderById(provider.vendorId ?? '')?.name;
      final saved = provider.copyWith(
        id: resolvedId,
        name: vendorName ?? provider.name,
      );
      await repo.insertSilently(saved);

      // 记录「旧行 id → 新引用」：角色绑定靠它改写
      final vendorId = (provider.vendorId ?? 'custom');
      for (final row in rows) {
        final rowVendor = (row['vendor_id'] as String?)?.trim();
        final rowProviderVendor =
            (rowVendor == null || rowVendor.isEmpty) ? 'custom' : rowVendor;
        if (rowProviderVendor != vendorId) continue;
        if (((row['base_url'] as String?) ?? '').trim() !=
            provider.baseUrl.trim()) {
          continue;
        }
        if (((row['provider'] as String?) ?? 'openai') !=
            provider.providerType) {
          continue;
        }
        final id = (row['id'] as String?) ?? '';
        final modelName = ((row['model_name'] as String?) ?? '').trim();
        if (id.isEmpty || modelName.isEmpty) continue;
        configIdToRef[id] =
            AiModelRef(providerId: saved.id, modelName: modelName);
      }
    }

    final rolesChanged = await _migrateRoles(configIdToRef);

    if (deleteLegacyRows) {
      // 旧行已全部归并，清掉本地副本（直接删库、不写 sync_log：
      // 写删除日志会让对端设备在它自己完成迁移前先把数据删了）
      final db = await DatabaseHelper.instance.database;
      await db.delete('ai_configs');
    }

    LoggerService.instance.logAI(
      '厂商条目迁移完成：旧配置 ${rows.length} 行 → 厂商 ${providers.length} 条',
      details: rolesChanged ? '角色绑定已改写' : '角色绑定无需改写',
    );
    return true;
  }

  /// 读取旧表原始行；表不存在（极老库）时返回空表
  Future<List<Map<String, dynamic>>> _readLegacyRows() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final maps = await db.query('ai_configs', orderBy: 'created_at ASC');
      return maps.map((m) => Map<String, dynamic>.from(m)).toList();
    } catch (e) {
      LoggerService.instance.logAI(
        '读取旧 ai_configs 失败，按无可迁移数据处理',
        details: e.toString(),
        level: LogLevel.warning,
      );
      return const [];
    }
  }

  /// 旧角色绑定（configId）改写为 AiModelRef；内置模型相关字段直接丢弃
  ///
  /// 返回是否写回了角色配置（无旧绑定且无内置字段残留时不动库）。
  Future<bool> _migrateRoles(Map<String, AiModelRef> configIdToRef) async {
    final repo = ConfigRepository.instance;
    final raw = await repo.getAppConfig('ai_roles');
    if (raw == null || raw.trim().isEmpty) return false;

    Map<String, dynamic> legacy;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      legacy = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return false;
    }

    AiModelRef? refOf(dynamic value) {
      final text = value?.toString().trim() ?? '';
      if (text.isEmpty) return null;
      // 已是新格式（含分隔符）就按新格式解析，兼容「迁移前已部分升级」
      final parsed = AiModelRef.tryParse(text);
      if (parsed != null) return parsed;
      return configIdToRef[text];
    }

    final migrated = AiRoles(
      assistant: refOf(legacy['assistant']),
      timelineOptimization: refOf(legacy['timelineOptimization']),
      // 旧生图绑定指向内置模型，随内置模型下线一并清空
      imageGeneration: refOf(legacy['imageGeneration']),
    );

    final hadLegacyFreeModelFields = legacy.keys.any((key) =>
        key.contains('UseFreeModel') ||
        key.contains('FreeModelId') ||
        key == 'imageGenerationFreeModelId');
    final hasBindings =
        migrated.assistant != null || migrated.timelineOptimization != null;
    if (!hadLegacyFreeModelFields && !hasBindings) return false;

    await repo.saveAiRoles(migrated);
    LoggerService.instance.logAI(
      '角色绑定迁移完成',
      details: 'assistant=${migrated.assistant?.encode() ?? '未绑定'}, '
          'timeline=${migrated.timelineOptimization?.encode() ?? '未绑定'}',
    );
    return true;
  }

  Future<void> _cleanLegacyPrefs(SharedPreferences prefs) async {
    for (final key in _legacyPrefKeys) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    }
    for (final key in prefs.getKeys()) {
      if (_legacyPrefPrefixes.any(key.startsWith)) {
        await prefs.remove(key);
      }
    }
  }
}