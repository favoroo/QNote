import 'dart:convert';

import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';

/// 小Q工具开关配置（对齐 Hermes Toolsets 的"核心直曝 + 扩展可停"分层）
///
/// 仅 [AgentToolRegistry.optionalToolNames] 中的可选工具可被禁用，
/// 核心工具（VFS 原语、skill、grep、ask_user）始终注册不受影响。
/// 配置持久化于 app_configs（键 [storageKey]），设置页与运行时共用同一份状态。
class AgentToolConfig {
  static final AgentToolConfig instance = AgentToolConfig._();
  AgentToolConfig._();

  static const String storageKey = 'agent_disabled_tools';

  /// 内存缓存（null 表示未加载）
  Set<String>? _cached;

  /// 读取被禁用的工具名集合
  Future<Set<String>> getDisabledTools() async {
    if (_cached != null) return _cached!;
    final raw = await ConfigRepository.instance.getAppConfig(storageKey);
    if (raw == null || raw.isEmpty) {
      return _cached = <String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        // 只保留合法的可选工具名，防御历史脏数据
        return _cached = decoded
            .whereType<String>()
            .where(AgentToolRegistry.optionalToolNames.contains)
            .toSet();
      }
    } catch (_) {}
    return _cached = <String>{};
  }

  /// 读取当前启用的可选工具名集合（全部可选 − 已禁用）
  Future<Set<String>> getEnabledOptionalTools() async {
    final disabled = await getDisabledTools();
    return AgentToolRegistry.optionalToolNames.difference(disabled);
  }

  /// 设置单个可选工具的启停（核心工具名会被拒绝）
  Future<void> setToolDisabled(String name, bool disabled) async {
    if (!AgentToolRegistry.optionalToolNames.contains(name)) {
      throw Exception('工具「$name」为核心工具，不可禁用');
    }
    final current = await getDisabledTools();
    if (disabled) {
      current.add(name);
    } else {
      current.remove(name);
    }
    await _save(current);
  }

  Future<void> _save(Set<String> disabled) async {
    _cached = disabled;
    await ConfigRepository.instance.setAppConfig(
      storageKey,
      jsonEncode(disabled.toList()),
    );
  }
}
