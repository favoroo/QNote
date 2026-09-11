import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';

/// 技能查阅与加载工具
class SkillTool extends AgentTool {
  final SkillRegistry _registry = SkillRegistry.instance;

  @override
  String get name => 'skill';

  @override
  String get description =>
      '查看或激活指定的专业技能手册（如 "todo-manager"、"note-manager"、"timeline-manager"、"journal-manager"、"settings-manager"）。当遇到用户复杂的规划、长文排版或特定领域需求时，调用此工具获取最佳工作流与格式规范。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '技能名称或技能文件路径（如 "todo-manager"、"note-manager" 或 "/skills/todo-manager.md"）。不填则列出所有可用技能。',
          },
        },
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final name = arguments['name'] as String?;
    if (name == null || name.trim().isEmpty) {
      final skills = _registry.listSkills();
      final buffer = StringBuffer();
      buffer.writeln('# 可用技能手册清单\n');
      for (final s in skills) {
        buffer.writeln('- **${s['name']}** (`${s['path']}`): ${s['description']}');
      }
      return ToolResult.success(
        buffer.toString().trimRight(),
        uiDetails: {'skills': skills},
      );
    }

    final content = _registry.getSkillContent(name);
    if (content == null) {
      return ToolResult.error(
        '未找到技能 "$name"。可用技能请调用 skill() 查看列表。',
      );
    }

    return ToolResult.success(
      content,
      uiDetails: {'name': name, 'loaded': true},
    );
  }
}
