import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/skills/explicit_skill_context.dart';

void main() {
  test('没有显式技能时不注入整段', () {
    expect(buildExplicitSkillContext(const []), isNull);
  });

  test('单技能：点名技能并原样带入手册，不出现多手册措辞', () {
    const doc = '---\nname: todo-manager\ndescription: 待办\n---\n\n# 待办管理';
    final section = buildExplicitSkillContext([(name: 'todo-manager', doc: doc)]);

    expect(section, isNotNull);
    expect(section, contains('`todo-manager`'));
    expect(section, contains('严格遵循该手册'));
    expect(section, contains(doc));
    expect(section, isNot(contains('多份手册')));
    expect(section, isNot(contains('技能 2')));
  });

  test('多技能：按传入顺序编号、全部手册保留，并声明冲突时以用户指令为准', () {
    const todoDoc = '# 待办管理';
    const mermaidDoc = '# 图示';
    final section = buildExplicitSkillContext([
      (name: 'todo-manager', doc: todoDoc),
      (name: 'mermaid-diagram', doc: mermaidDoc),
    ]);

    expect(section, isNotNull);
    expect(section, contains('`todo-manager`、`mermaid-diagram`'));
    expect(section, contains('多份手册需配合使用，冲突时以用户当前指令为准'));
    expect(section!.indexOf('## 技能 1：todo-manager'), lessThan(section.indexOf('## 技能 2：mermaid-diagram')));
    expect(section.indexOf(todoDoc), lessThan(section.indexOf(mermaidDoc)));
    expect(section, isNot(contains('严格遵循该手册')));
  });
}
