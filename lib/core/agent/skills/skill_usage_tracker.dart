import 'dart:convert';

import 'package:qnote_flutter/core/storage/config_repository.dart';

/// 单个技能的使用统计快照
class SkillUsageStat {
  /// 累计使用次数（斜杠命令调用 + 小Q经 skill 工具加载）
  final int count;

  /// 最近一次使用时间；从未使用过为 null
  final DateTime? lastUsedAt;

  const SkillUsageStat({required this.count, this.lastUsedAt});

  factory SkillUsageStat.fromMap(Map<String, dynamic> map) => SkillUsageStat(
        count: (map['count'] as num?)?.toInt() ?? 0,
        lastUsedAt: map['lastUsedAt'] != null
            ? DateTime.tryParse(map['lastUsedAt'] as String)
            : null,
      );

  Map<String, dynamic> toMap() => {
        'count': count,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
      };
}

/// 技能使用统计追踪器（Curator 轻量版）
///
/// 记录每个技能（内置 + 用户自定义）被真实使用的次数与最近使用时间，
/// 持久化于 app_configs（键 `agent_skill_usage`，参与云同步），
/// 供「小Q技能」管理页展示使用徽标、辅助用户判断哪些技能值得归档。
class SkillUsageTracker {
  static const String storageKey = 'agent_skill_usage';

  static final SkillUsageTracker instance = SkillUsageTracker._();
  SkillUsageTracker._();

  /// 全量统计缓存（技能名 → 统计）；record 后失效，下次读取时重建
  Map<String, SkillUsageStat>? _cache;

  /// 读取全部技能的使用统计
  Future<Map<String, SkillUsageStat>> getStats() async {
    final cached = _cache;
    if (cached != null) return cached;

    final raw = await ConfigRepository.instance.getAppConfig(storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return _cache = decoded.map(
        (name, value) => MapEntry(
          name,
          SkillUsageStat.fromMap(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      // 历史数据损坏时按无统计兜底，不阻断技能管理页
      return {};
    }
  }

  /// 记录一次技能使用；未命中既有数据时自动初始化。
  /// 失败静默（统计丢失不影响主流程）。
  Future<void> record(String skillName) async {
    final name = skillName.trim();
    if (name.isEmpty) return;
    try {
      final stats = await getStats();
      final current = stats[name] ?? const SkillUsageStat(count: 0);
      stats[name] = SkillUsageStat(
        count: current.count + 1,
        lastUsedAt: DateTime.now(),
      );
      _cache = stats;
      await ConfigRepository.instance.setAppConfig(
        storageKey,
        jsonEncode(stats.map((k, v) => MapEntry(k, v.toMap()))),
      );
    } catch (_) {
      // 持久化失败仅放弃本次统计，保持缓存供本会话内读取
    }
  }

  /// 技能被删除后清理其统计记录
  Future<void> remove(String skillName) async {
    final name = skillName.trim();
    if (name.isEmpty) return;
    try {
      final stats = await getStats();
      if (stats.remove(name) == null) return;
      _cache = stats;
      await ConfigRepository.instance.setAppConfig(
        storageKey,
        jsonEncode(stats.map((k, v) => MapEntry(k, v.toMap()))),
      );
    } catch (_) {
      // 清理失败无碍主流程
    }
  }
}
