/// 组合「本轮显式指定技能」注入到 system 上下文的段落。
///
/// 入参为 `SkillRegistry.resolveSkillDocs` 的结果（已归一主名、按主名去重、保序）。
/// 单技能与多技能使用不同措辞：多份手册可能互相冲突，必须明确以用户当前指令为准；
/// 空列表返回 null，调用方据此跳过整段注入。
String? buildExplicitSkillContext(List<({String name, String doc})> skills) {
  if (skills.isEmpty) return null;

  final names = skills.map((skill) => '`${skill.name}`').join('、');
  final docs = [for (var i = 0; i < skills.length; i++) '## 技能 ${i + 1}：${skills[i].name}\n${skills[i].doc}'];

  if (skills.length > 1) {
    return '激活技能手册（用户在本轮显式指定 $names，请严格遵循对应手册执行本次任务；'
        '多份手册需配合使用，冲突时以用户当前指令为准）:\n\n${docs.join('\n\n')}';
  }
  return '激活技能手册（用户在本轮显式指定 $names，请严格遵循该手册的规范执行本次任务）:\n\n${docs.single}';
}
