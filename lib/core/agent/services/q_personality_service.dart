import 'dart:convert';

import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';

/// 小Q个性配置服务：读写当前激活个性与自定义人格文本
///
/// 对齐 Hermes 的 SOUL.md 语义：个性在每次对话开始时读取一次并注入系统提示词，
/// 本轮中途的修改不回填当前上下文，下轮对话生效。
/// 配置持久化于 app_configs（键 [storageKey]），VFS `/settings/personality.json`
/// 的读写最终也落到这里，保证 UI 设置页与小Q自我调整共用同一份状态。
class QPersonalityService {
  static final QPersonalityService instance = QPersonalityService._();
  QPersonalityService._();

  static const String storageKey = 'agent_personality';

  /// 内存缓存（null 表示未加载），VFS 写入后调用 [refresh] 失效
  Map<String, dynamic>? _cached;

  /// 读取当前激活的个性（custom 时拼接用户自编文本作为 prompt）
  Future<QPersonality> getActivePersonality() async {
    final config = await _loadConfig();
    final id = (config['activeId'] as String?)?.trim();
    final preset = QPersonalities.byId(id ?? '');
    if (preset.id != QPersonalities.customId) {
      return preset;
    }
    final customText = (config['customPrompt'] as String?)?.trim() ?? '';
    // 自定义为空时回退经典管家，避免拼出无人格的提示词
    if (customText.isEmpty) {
      return QPersonalities.byId(QPersonalities.defaultId);
    }
    return QPersonality(
      id: preset.id,
      name: preset.name,
      description: preset.description,
      prompt: customText,
    );
  }

  /// 读取当前激活个性 id（设置页选中态用）
  Future<String> getActiveId() async {
    final config = await _loadConfig();
    return (config['activeId'] as String?) ?? QPersonalities.defaultId;
  }

  /// 切换激活个性（未知 id 拒绝写入）
  Future<void> setActiveId(String id) async {
    final known = QPersonalities.presets.any((p) => p.id == id);
    if (!known) {
      throw Exception('未知的个性标识: $id');
    }
    final config = await _loadConfig();
    config['activeId'] = id;
    await _saveConfig(config);
  }

  /// 读取自定义人格文本
  Future<String> getCustomPrompt() async {
    final config = await _loadConfig();
    return (config['customPrompt'] as String?) ?? '';
  }

  /// 保存自定义人格文本
  Future<void> setCustomPrompt(String text) async {
    final config = await _loadConfig();
    config['customPrompt'] = text;
    await _saveConfig(config);
  }

  /// 从配置映射增量更新（VFS `/settings/personality.json` 写入通道）：
  /// 只接受合法的 activeId 与字符串 customPrompt，其余字段忽略
  Future<void> applyPartialConfig(Map<String, dynamic> partial) async {
    final config = await _loadConfig();
    if (partial.containsKey('activeId')) {
      final id = partial['activeId']?.toString().trim() ?? '';
      if (QPersonalities.presets.any((p) => p.id == id)) {
        config['activeId'] = id;
      }
    }
    if (partial.containsKey('customPrompt')) {
      config['customPrompt'] = partial['customPrompt']?.toString() ?? '';
    }
    await _saveConfig(config);
  }

  /// 强制清除内存缓存（VFS 写入、云同步导入后刷新用）
  Future<void> refresh() async {
    _cached = null;
    await _loadConfig();
  }

  Future<Map<String, dynamic>> _loadConfig() async {
    if (_cached != null) return _cached!;
    final raw = await ConfigRepository.instance.getAppConfig(storageKey);
    if (raw == null || raw.isEmpty) {
      return _cached = {
        'activeId': QPersonalities.defaultId,
        'customPrompt': '',
      };
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return _cached = decoded;
      }
    } catch (_) {}
    return _cached = {
      'activeId': QPersonalities.defaultId,
      'customPrompt': '',
    };
  }

  Future<void> _saveConfig(Map<String, dynamic> config) async {
    _cached = config;
    await ConfigRepository.instance.setAppConfig(
      storageKey,
      jsonEncode(config),
    );
  }
}
