import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/agent_skill.dart';

void main() {
  group('AgentSkill 用户技能模型', () {
    test('JSON 序列化往返', () {
      final skill = AgentSkill(
        name: 'invest-review',
        description: '投资复盘技能',
        content: '# 投资复盘技能',
      );
      final restored = AgentSkill.fromJson(skill.toJson());
      expect(restored.name, skill.name);
      expect(restored.description, skill.description);
      expect(restored.content, skill.content);
    });

    test('toMarkdown 合成 frontmatter 与内置技能格式一致', () {
      final skill = AgentSkill(
        name: 'my-skill',
        description: '描述',
        content: '# 正文',
      );
      final md = skill.toMarkdown();
      expect(md.startsWith('---\nname: my-skill\n'), isTrue);
      expect(md.contains('description: 描述'), isTrue);
      expect(md.endsWith('# 正文'), isTrue);
      // JSON 值中不含未转义的裸 frontmatter 冲突字符
      expect(jsonDecode(skill.toJson()), isMap);
    });

    test('pathOf 生成虚拟文件路径', () {
      expect(AgentSkill.pathOf('my-skill'), '/skills/my-skill.md');
    });

    test('isValidName 校验非法名称', () {
      expect(AgentSkill.isValidName('my-skill'), isTrue);
      expect(AgentSkill.isValidName('投资复盘'), isTrue);
      expect(AgentSkill.isValidName(''), isFalse);
      expect(AgentSkill.isValidName('my skill'), isFalse);
      expect(AgentSkill.isValidName('a/b'), isFalse);
      expect(AgentSkill.isValidName('.hidden'), isFalse);
      expect(AgentSkill.isValidName('x' * 41), isFalse);
    });

    test('copyWith 保留未指定字段', () {
      final skill = AgentSkill(
        name: 'a',
        description: 'd',
        content: 'c',
        updatedAt: DateTime(2026),
      );
      final updated = skill.copyWith(description: 'new');
      expect(updated.name, 'a');
      expect(updated.description, 'new');
      expect(updated.content, 'c');
      expect(updated.updatedAt, DateTime(2026));
    });
  });
}
