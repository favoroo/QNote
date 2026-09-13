import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/models/agent_skill.dart';

/// 小Q技能清单（内置技能 + 用户自定义技能，含来源标记）
///
/// 数据统一经 [SkillRegistry]（内置为 Dart 常量，用户技能缓存 + app_configs 持久化）；
/// 小Q Agent 经 VFS 写入 `/skills/*.md` 时会广播事件，此处监听后自动刷新，
/// 保证「小Q技能」管理页与小Q的写入双向实时同步
final agentSkillListProvider =
    AsyncNotifierProvider<AgentSkillNotifier, List<Map<String, String>>>(() {
  return AgentSkillNotifier();
});

class AgentSkillNotifier
    extends AsyncNotifier<List<Map<String, String>>> {
  void _onWorkspaceChange(WorkspaceChangeEvent event) {
    if (event.path.startsWith('/skills/')) {
      ref.invalidateSelf();
    }
  }

  @override
  Future<List<Map<String, String>>> build() async {
    // addListener 内部按引用去重，build 重复执行不会重复注册
    WorkspaceEventBus.instance.addListener(_onWorkspaceChange);
    ref.onDispose(
      () => WorkspaceEventBus.instance.removeListener(_onWorkspaceChange),
    );
    // 每次构建强制重载，拾取云同步导入等其他来源的数据变更
    await SkillRegistry.instance.reload();
    // 管理页需要展示已归档技能（带 archived 标记），故全量返回
    return SkillRegistry.instance.listSkills(includeArchived: true);
  }

  /// 新建或更新一个用户技能（名称冲突/非法由 SkillRegistry 校验并抛出）
  Future<void> saveUserSkill(AgentSkill skill) async {
    await SkillRegistry.instance.saveUserSkill(skill);
    ref.invalidateSelf();
  }

  /// 删除一个用户技能（内置技能由 SkillRegistry 拒绝）
  Future<void> deleteUserSkill(String name) async {
    await SkillRegistry.instance.deleteUserSkill(name);
    ref.invalidateSelf();
  }

  /// 归档或恢复一个用户技能（归档后对小Q与斜杠命令不可见，手册保留）
  Future<void> archiveUserSkill(String name, bool archived) async {
    await SkillRegistry.instance.archiveUserSkill(name, archived);
    ref.invalidateSelf();
  }
}
